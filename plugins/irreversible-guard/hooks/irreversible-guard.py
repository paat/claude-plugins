#!/usr/bin/env python3
"""irreversible-guard PreToolUse matcher.

Blocks Bash commands that have no practical local undo. Reads the tiered
deny-set from rules/deny-set.json (with an inline fallback) and an optional
per-project config at .claude/irreversible-guard.json. See the plugin README.
"""
import json, os, re, shlex, sys
from collections import namedtuple

OUTCOME_BLOCK, OUTCOME_WARN, OUTCOME_PASS = "BLOCK", "WARN", "PASS"
SEVERITY = {OUTCOME_PASS: 0, OUTCOME_WARN: 1, OUTCOME_BLOCK: 2}
Atom = namedtuple("Atom", ["argv", "context"])
SEPARATORS = re.compile(r'\s*(?:&&|\|\||;|\||\n)\s*')
HEREDOC = re.compile(r'<<-?\s*[\'"]?([A-Za-z_]\w*)[\'"]?')
ENVPREFIX = re.compile(r'^[A-Za-z_]\w*=')
# Flags that consume the following token as a value. Used to drop flag *values*
# when extracting the positional (non-flag) tokens of a command, so that a global
# flag like `kubectl --context prod delete namespace` does not hide the verb.
VALUE_FLAGS = {"-p", "--profile", "--region", "--project", "-n", "--namespace",
               "--context", "--cluster", "-u", "--user", "--config",
               "--kubeconfig", "-i", "-o", "-l", "-F", "-C", "--chdir"}

DEFAULT_RULES = {
 # Structured "binary + subcommand" rules — matched on exact positional tokens
 # (flag/flag-value aware) so intervening global flags cannot smuggle the verb past.
 "tier1_cmd": [
   {"seq": ["terraform", "destroy"]}, {"seq": ["tofu", "destroy"]},
   {"seq": ["fly", "volumes", "destroy"]}, {"seq": ["flyctl", "volumes", "destroy"]},
   {"seq": ["railway", "volume", "delete"]},
   {"seq": ["aws", "s3", "rb"]}, {"seq": ["aws", "s3", "rm"], "flag": "--recursive"},
   {"seq": ["aws", "ec2", "delete-volume"]},
   {"seq": ["aws", "rds", ["delete-db-instance", "delete-db-cluster"]]},
   {"seq": ["gcloud", "sql", "instances", "delete"]},
   {"seq": ["gcloud", "compute", "disks", "delete"]},
   {"seq": ["heroku", "pg:reset"]},
   {"seq": ["kubectl", "delete", ["namespace", "ns", "pv", "pvc"]]}],
 "tier1_regex": [r'\bdd\b[^\n]*\bof=/dev/', r'\bmkfs(\.\w+)?\b', r'\bwipefs\b'],
 "tier2_regex": [
   r'\bDROP\s+(TABLE|DATABASE)\b', r'\bTRUNCATE\b', r'\bef\s+database\s+drop\b',
   r'\bdocker[\s-]compose\b[^\n]*\bdown\b[^\n]*(--volumes|\s-v\b)',
   r'\bdocker\s+volume\s+(rm|prune)\b'],
 "warn_regex": [
   r'\bgit\s+push\b[^\n]*(--force\b|--force-with-lease\b|\s-f\b)',
   r'\bgit\s+reset\s+--hard\b', r'\bgit\s+clean\s+-\w*[fd]\w*'],
 "prod_markers": ["*prod*", "*production*", "*-live"], "allow": [], "extra_block": [], "warn_only": []}


def load_rules(plugin_root, cwd):
    rules = json.loads(json.dumps(DEFAULT_RULES))
    try:
        with open(os.path.join(plugin_root, "rules", "deny-set.json")) as f:
            rules.update(json.load(f))
    except Exception:
        pass
    try:
        with open(os.path.join(cwd, ".claude", "irreversible-guard.json")) as f:
            user = json.load(f)
        for k in ("allow", "extra_block", "warn_only"):
            rules[k] = list(rules.get(k, [])) + list(user.get(k, []))
        if user.get("prod_markers"):
            rules["prod_markers"] = list(user["prod_markers"])
    except Exception:
        pass
    return rules


def _after_exec(args):
    i = 0
    while i < len(args) and args[i].startswith("-"):
        i += 2 if args[i] in ("-e", "--env", "-u", "--user", "-w", "--workdir") else 1
    if i >= len(args):
        return None, ""
    return (args[i+1:] or None), args[i]


def _docker_inner(t):
    r = t[1:]
    if r and r[0] == "exec":
        return _after_exec(r[1:])
    if r and r[0] == "compose" and "exec" in r:
        return _after_exec(r[r.index("exec")+1:])
    return None, ""


def _ssh_inner(t):
    a = t[1:]; i = 0
    while i < len(a) and a[i].startswith("-"):
        if a[i] == "--":
            i += 1
            break
        i += 2 if a[i] in ("-p", "-i", "-o", "-l", "-F") else 1
    if i >= len(a):
        return None, ""
    return (" ".join(a[i+1:]) or None), a[i]


def _extract_heredocs(cmd):
    lines = cmd.split("\n"); bodies = []; out = []; i = 0
    while i < len(lines):
        m = HEREDOC.search(lines[i])
        if m:
            d = m.group(1); inv = lines[i]; out.append(lines[i]); i += 1; body = []
            while i < len(lines) and lines[i].strip().rstrip("'\"") != d:
                body.append(lines[i]); i += 1
            bodies.append((inv, "\n".join(body))); i += 1
        else:
            out.append(lines[i]); i += 1
    return bodies, "\n".join(out)


def deobfuscate(cmd, context=None, depth=0):
    context = context or []; atoms = []
    if depth > 5:
        return atoms
    bodies, stripped = _extract_heredocs(cmd)
    chunks = [(stripped, context)] + [(b, context + [inv]) for inv, b in bodies]
    for chunk, ctx in chunks:
        for s in SEPARATORS.split(chunk):
            s = s.strip()
            if not s:
                continue
            try:
                toks = shlex.split(s)
            except ValueError:
                toks = s.split()
            while toks and ENVPREFIX.match(toks[0]):
                toks.pop(0)
            if toks and toks[0] == "--":
                toks.pop(0)
            if not toks:
                continue
            v = os.path.basename(toks[0])
            if v == "ssh":
                inner, tg = _ssh_inner(toks)
                if inner:
                    atoms += deobfuscate(inner, ctx + [tg], depth + 1); continue
            if v in ("bash", "sh") and "-c" in toks:
                j = toks.index("-c")
                if j + 1 < len(toks):
                    atoms += deobfuscate(toks[j+1], ctx, depth + 1); continue
            if v == "eval" and len(toks) > 1:
                atoms += deobfuscate(" ".join(toks[1:]), ctx, depth + 1); continue
            if v in ("docker", "docker-compose"):
                inner, tg = _docker_inner(toks)
                if inner:
                    atoms.append(Atom(inner, ctx + [tg])); continue
            atoms.append(Atom(toks, ctx))
    return atoms


def _prod_marked(hay, rules):
    h = hay.lower()
    for m in rules.get("prod_markers", []):
        core = m.strip("*").lower()
        if core and core in h:
            return True
    return False


def _nonflag(argv):
    """Positional tokens, dropping flags and the values of value-taking flags."""
    out = []; skip = False
    for a in argv:
        if skip:
            skip = False
            continue
        if a.startswith("-"):
            if a in VALUE_FLAGS:
                skip = True
            continue
        out.append(a)
    return out


def _seq_match(argv, seq):
    """True if seq appears as contiguous positional tokens. Each seq element is a
    token, or a list of acceptable alternatives."""
    toks = _nonflag(argv); n = len(seq)
    if not n:
        return False
    for s in range(len(toks) - n + 1):
        if all(toks[s+k] in (w if isinstance(w, list) else [w]) for k, w in enumerate(seq)):
            return True
    return False


def _is_protected_target(t, cwd):
    raw = t
    if raw in ("/", "~", "~/", "$HOME", "${HOME}", "*", ".*", "./*",
               "~/*", "$HOME/*", "${HOME}/*"):
        return True
    exp = os.path.expanduser(raw.replace("${HOME}", "~").replace("$HOME", "~"))
    home = os.path.normpath(os.path.expanduser("~"))
    if os.path.isabs(exp):
        norm = os.path.normpath(exp); parts = [p for p in norm.split("/") if p]
        if norm in ("/", "//") or len(parts) <= 1:
            return True
        if parts[0] in ("opt", "srv", "data"):
            return True
        if norm.startswith("/var/lib"):
            return True
        if norm == home:
            return True
    else:
        cand = os.path.normpath(os.path.join(cwd, exp))
        if cand == os.path.normpath(cwd):
            return True
        if not (cand + os.sep).startswith(os.path.normpath(cwd) + os.sep):
            return True
    return False


def _rm_protected(argv, cwd):
    flags = [a for a in argv[1:] if a.startswith("-")]
    targets = [a for a in argv[1:] if not a.startswith("-")]
    if "--no-preserve-root" in flags:
        return True
    fs = "".join(flags)
    if not any(c in fs for c in ("r", "R")):
        return False
    return any(_is_protected_target(t, cwd) for t in targets)


def _match(p, text):
    if len(p) >= 2 and p[0] == "/" and p[-1] == "/":
        try:
            return re.search(p[1:-1], text, re.I) is not None
        except re.error:
            return False
    return p in text


def classify_atom(atom, rules, cwd):
    cmd = " ".join(atom.argv); hay = cmd + " " + " ".join(atom.context)
    for p in rules.get("allow", []):
        if _match(p, cmd):
            return OUTCOME_PASS, ""
    outcome, reason = OUTCOME_PASS, ""
    if atom.argv and os.path.basename(atom.argv[0]) == "rm" and _rm_protected(atom.argv, cwd):
        outcome, reason = OUTCOME_BLOCK, "rm of a protected/irreversible path: " + cmd
    if outcome != OUTCOME_BLOCK:
        for entry in rules.get("tier1_cmd", []):
            if _seq_match(atom.argv, entry.get("seq", [])):
                flag = entry.get("flag")
                if flag and flag not in atom.argv:
                    continue
                outcome, reason = OUTCOME_BLOCK, "irreversible op: " + cmd
                break
    if outcome != OUTCOME_BLOCK:
        for p in rules.get("tier1_regex", []) + rules.get("extra_block", []):
            if re.search(p, cmd, re.I):
                outcome, reason = OUTCOME_BLOCK, "irreversible op: " + cmd
                break
    if outcome != OUTCOME_BLOCK:
        for p in rules.get("tier2_regex", []):
            if re.search(p, cmd, re.I):
                if _prod_marked(hay, rules):
                    outcome, reason = OUTCOME_BLOCK, "destructive op against production: " + cmd
                break
    if outcome == OUTCOME_PASS:
        for p in rules.get("warn_regex", []):
            if re.search(p, cmd, re.I):
                outcome, reason = OUTCOME_WARN, "recoverable but destructive: " + cmd
                break
    if outcome == OUTCOME_BLOCK:
        for p in rules.get("warn_only", []):
            if _match(p, cmd):
                return OUTCOME_WARN, "downgraded (warn_only): " + cmd
    return outcome, reason


def classify(cmd, rules, cwd):
    out, reason = OUTCOME_PASS, ""
    for a in deobfuscate(cmd):
        o, r = classify_atom(a, rules, cwd)
        if SEVERITY[o] > SEVERITY[out]:
            out, reason = o, r
    return out, reason


def main():
    raw = sys.stdin.read()
    try:
        payload = json.loads(raw)
    except Exception:
        return 0
    if payload.get("tool_name") != "Bash":
        return 0
    command = (payload.get("tool_input") or {}).get("command", "")
    if not command.strip():
        return 0
    cwd = payload.get("cwd") or os.getcwd()
    plugin_root = os.environ.get("CLAUDE_PLUGIN_ROOT") or \
        os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    rules = load_rules(plugin_root, cwd)
    try:
        outcome, reason = classify(command, rules, cwd)
    except Exception as e:
        sys.stderr.write("[irreversible-guard] internal error, allowing: %s\n" % e)
        return 0
    if outcome == OUTCOME_BLOCK:
        sys.stderr.write(
            "[irreversible-guard] BLOCKED: %s\n"
            "This operation has no practical undo. If you are certain it is safe, add an "
            "`allow` pattern to .claude/irreversible-guard.json and retry.\n" % reason)
        return 2
    if outcome == OUTCOME_WARN:
        note = "[irreversible-guard] CAUTION: %s (recoverable; proceeding)" % reason
        print(json.dumps({"hookSpecificOutput": {
            "hookEventName": "PreToolUse", "additionalContext": note}}))
        return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
