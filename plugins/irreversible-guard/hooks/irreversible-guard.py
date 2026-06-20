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
HEREDOC = re.compile(r'<<-?\s*[\'"]?([A-Za-z_]\w*)[\'"]?')
ENVPREFIX = re.compile(r'^[A-Za-z_]\w*=')
REDIRECTS = (">", ">>", "<", "<<", ">&", "&>", "|", "tee")


def _split_segments(s):
    """Split on && || ; | and newlines, but only outside quotes (quote-aware),
    so separators inside a `bash -c '... && ...'` payload are not split early."""
    segs = []; buf = []; i = 0; q = None; n = len(s)
    while i < n:
        c = s[i]
        if q:
            buf.append(c)
            if c == q:
                q = None
            i += 1; continue
        if c in ("'", '"'):
            q = c; buf.append(c); i += 1; continue
        if c == "\\" and i + 1 < n:
            buf.append(c); buf.append(s[i+1]); i += 2; continue
        if c in (";", "\n"):
            segs.append("".join(buf)); buf = []; i += 1; continue
        if c == "&":
            nxt = s[i+1] if i + 1 < n else ""
            if nxt == "&":  # && separator
                segs.append("".join(buf)); buf = []; i += 2; continue
            if nxt == ">" or (buf and buf[-1] == ">"):  # part of &> or 2>&1 redirect
                buf.append(c); i += 1; continue
            segs.append("".join(buf)); buf = []; i += 1; continue  # background &
        if c == "|":
            segs.append("".join(buf)); buf = []
            i += 2 if (i + 1 < n and s[i+1] == "|") else 1
            continue
        buf.append(c); i += 1
    segs.append("".join(buf))
    return [x for x in segs if x.strip()]
# Flags that consume the following token as a value. Used to drop flag *values*
# when extracting positional (non-flag) tokens, so a global flag like
# `kubectl --context prod delete namespace` or `docker compose -f prod.yml down -v`
# cannot hide the verb.
VALUE_FLAGS = {"-p", "--profile", "--region", "--project", "-n", "--namespace",
               "--context", "--cluster", "-u", "--user", "--config",
               "--kubeconfig", "-i", "-o", "-l", "-F", "-C", "--chdir",
               "-f", "--file", "-H", "--host"}
# Shells we unwrap `-c`/`-lc`/`-ec` from.
SHELLS = ("bash", "sh", "zsh", "ash", "dash")
# Prefix wrappers that run their (post-flag) operand as the real command, mapped
# to that wrapper's value-taking flags (so `time -p`/`command -p` stay boolean but
# `sudo -u user` / `ionice -c 2` consume their value). The inner is already-split
# argv, re-joined and recursed.
ARGV_WRAPPERS = {
    "command": set(), "builtin": set(), "nohup": set(), "setsid": set(),
    "time": set(),
    "stdbuf": {"-i", "-o", "-e", "--input", "--output", "--error"},
    "nice": {"-n", "--adjustment"},
    "ionice": {"-c", "--class", "-n", "--classdata", "-p", "--pid"},
    "sudo": {"-u", "--user", "-g", "--group", "-p", "--prompt", "-C",
             "--close-from", "-r", "--role", "-t", "--type", "-U",
             "--other-user", "-h", "--host", "-D", "--chdir", "-R", "--chroot"},
    "doas": {"-u", "-C"},
    "xargs": {"-n", "--max-args", "-L", "--max-lines", "-I", "-i", "--replace",
              "-P", "--max-procs", "-d", "--delimiter", "-E", "-s",
              "--max-chars", "-a", "--arg-file"}}
FLOCK_VALUE_FLAGS = {"-w", "--timeout", "-E", "--conflict-exit-code"}
# DB clients — Tier-2 SQL only counts when the command is actually a client call.
DB_CLIENTS = {"psql", "mysql", "mysqladmin", "mariadb", "mongosh", "mongo",
              "sqlite3", "cockroach", "pgcli", "mycli", "dotnet"}
# Top-level dirs whose recursive deletion has no practical undo. NOTE: `var` is
# intentionally excluded (only /var/lib is protected, checked separately) so that
# routine /var/tmp and /var/cache cleanup is not blocked.
CRITICAL_ROOTS = {"etc", "usr", "bin", "sbin", "lib", "lib64", "boot",
                  "sys", "proc", "dev", "opt", "srv", "data", "root", "home"}

DEFAULT_RULES = {
 # Structured "binary + subcommand" rules — matched on exact positional tokens
 # (flag/flag-value aware) so intervening global flags cannot smuggle the verb past.
 "tier1_cmd": [
   {"seq": ["terraform", "destroy"]}, {"seq": ["tofu", "destroy"]},
   {"seq": ["terraform", "apply"], "flag": "-destroy"},
   {"seq": ["tofu", "apply"], "flag": "-destroy"},
   {"seq": ["fly", "volumes", "destroy"]}, {"seq": ["flyctl", "volumes", "destroy"]},
   {"seq": ["railway", "volume", "delete"]},
   {"seq": ["aws", "s3", "rb"]}, {"seq": ["aws", "s3", "rm"], "flag": "--recursive"},
   {"seq": ["aws", "ec2", "delete-volume"]},
   {"seq": ["aws", "rds", ["delete-db-instance", "delete-db-cluster"]]},
   {"seq": ["gcloud", "sql", "instances", "delete"]},
   {"seq": ["gcloud", "compute", "disks", "delete"]},
   {"seq": ["heroku", "pg:reset"]},
   {"seq": ["kubectl", "delete",
            ["namespace", "namespaces", "ns", "pv", "persistentvolume",
             "persistentvolumes", "pvc", "persistentvolumeclaim",
             "persistentvolumeclaims"]]}],
 "tier1_regex": [r'\bdd\b[^\n]*\bof=/dev/', r'\bmkfs(\.\w+)?\b', r'\bwipefs\b'],
 # Tier-2 structured commands — block only when the command names production.
 "tier2_cmd": [
   {"seq": ["docker", "volume", "rm"]}, {"seq": ["docker", "volume", "prune"]},
   {"seq": ["docker", "compose", "down"], "flag_any": ["-v", "--volumes"]},
   {"seq": ["docker-compose", "down"], "flag_any": ["-v", "--volumes"]}],
 # Tier-2 SQL — block only when prod-marked AND issued via a DB client.
 "tier2_sql_regex": [r'\bDROP\s+(TABLE|DATABASE)\b', r'\bTRUNCATE\b'],
 # Tier-2 other — block only when prod-marked.
 "tier2_regex": [r'\bef\s+database\s+drop\b'],
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
    # Skip docker global flags (and their values) to find exec / compose exec.
    args = t[1:]; i = 0
    while i < len(args) and args[i].startswith("-"):
        i += 2 if args[i] in VALUE_FLAGS else 1
    if i < len(args) and args[i] == "exec":
        return _after_exec(args[i+1:])
    if i < len(args) and args[i] == "compose":
        rest = args[i+1:]
        if "exec" in rest:
            return _after_exec(rest[rest.index("exec")+1:])
    return None, ""


def _env_inner(toks):
    """Unwrap `env [opts] [VAR=val ...] cmd args`. Returns (inner_cmd_str, assigns).
    Handles `env -S '<cmd>'` / `--split-string`, where the value is itself a command."""
    rest = toks[1:]; i = 0; assigns = []
    while i < len(rest):
        tk = rest[i]
        if tk in ("-S", "--split-string"):
            parts = ([rest[i+1]] if i + 1 < len(rest) else []) + rest[i+2:]
            return (" ".join(parts) if parts else None), assigns
        if tk.startswith("-S") and len(tk) > 2:
            return " ".join([tk[2:]] + rest[i+1:]), assigns
        if tk.startswith("--split-string="):
            return " ".join([tk[len("--split-string="):]] + rest[i+1:]), assigns
        if tk in ("-u", "--unset", "-C", "--chdir"):
            i += 2; continue
        if tk.startswith("-"):
            i += 1; continue
        if ENVPREFIX.match(tk):
            assigns.append(tk); i += 1; continue
        break
    inner = rest[i:]
    return (shlex.join(inner) if inner else None), assigns


def _su_inner(toks):
    """Unwrap `su [-] [user] -c '<cmd>'` — return the -c command string."""
    for k in range(1, len(toks)):
        if toks[k] == "-c" and k + 1 < len(toks):
            return toks[k+1]
    return None


def _wrapper_inner(rest, value_flags, skip_pos=0):
    """Skip leading flags (consuming values for value_flags) and skip_pos
    positionals, return the remaining argv list (the wrapped command) or None."""
    k = 0
    while k < len(rest):
        tk = rest[k]
        if tk == "--":
            k += 1; break
        if tk in value_flags:
            k += 2; continue
        if tk.startswith("-"):
            k += 1; continue
        break
    for _ in range(skip_pos):
        if k < len(rest):
            k += 1
    inner = rest[k:]
    return inner or None


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


def _shell_c_inner(toks):
    """For bash/sh/zsh ... -c|-lc|-ec '<cmd>', return the inner command string.
    Skips shell options that take a value (-o/-O/+o/+O/--rcfile/--init-file)."""
    i = 1
    while i < len(toks):
        tk = toks[i]
        if tk == "-c" or (tk.startswith("-") and not tk.startswith("--") and "c" in tk):
            return toks[i+1] if i + 1 < len(toks) else None
        if tk in ("-o", "+o", "-O", "+O", "--rcfile", "--init-file"):
            i += 2; continue
        if tk.startswith("-"):
            i += 1; continue
        break  # reached an operand (e.g. a script path) before any -c
    return None


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
    if depth > 25:
        # Pathological nesting: stop recursing but still classify the raw remainder
        # (fail safe) rather than dropping a possibly-dangerous command silently.
        try:
            return [Atom(shlex.split(cmd), context)]
        except ValueError:
            return [Atom(cmd.split(), context)]
    bodies, stripped = _extract_heredocs(cmd)
    chunks = [(stripped, context)] + [(b, context + [inv]) for inv, b in bodies]
    for chunk, ctx in chunks:
        for s in _split_segments(chunk):
            s = s.strip()
            if not s:
                continue
            try:
                toks = shlex.split(s)
            except ValueError:
                toks = s.split()
            env = []
            while toks and ENVPREFIX.match(toks[0]):
                env.append(toks.pop(0))  # keep as context — names may carry prod markers
            if toks and toks[0] == "--":
                toks.pop(0)
            if not toks:
                continue
            lctx = ctx + env
            v = os.path.basename(toks[0])
            if v == "env":
                inner, assigns = _env_inner(toks)
                if inner:
                    atoms += deobfuscate(inner, lctx + assigns, depth + 1); continue
            if v == "su":
                inner = _su_inner(toks)
                if inner:
                    atoms += deobfuscate(inner, lctx, depth + 1); continue
            if v == "watch":  # runs its operand as a shell command string
                inner = _wrapper_inner(toks[1:], {"-n", "--interval"})
                if inner:
                    atoms += deobfuscate(" ".join(inner), lctx, depth + 1); continue
            if v == "flock":  # flock [opts] <lockfile> <cmd...>
                inner = _wrapper_inner(toks[1:], FLOCK_VALUE_FLAGS, skip_pos=1)
                if inner:
                    atoms += deobfuscate(shlex.join(inner), lctx, depth + 1); continue
            if v in ARGV_WRAPPERS:  # sudo/doas/command/nohup/nice/ionice/xargs/...
                inner = _wrapper_inner(toks[1:], ARGV_WRAPPERS[v])
                if inner:
                    atoms += deobfuscate(shlex.join(inner), lctx, depth + 1); continue
            if v == "ssh":
                inner, tg = _ssh_inner(toks)
                if inner:
                    atoms += deobfuscate(inner, lctx + [tg], depth + 1); continue
            if v in SHELLS:
                inner = _shell_c_inner(toks)
                if inner:
                    atoms += deobfuscate(inner, lctx, depth + 1); continue
            if v == "eval" and len(toks) > 1:
                atoms += deobfuscate(" ".join(toks[1:]), lctx, depth + 1); continue
            if v in ("docker", "docker-compose"):
                inner, _tg = _docker_inner(toks)
                if inner:
                    # carry the full docker invocation as context so prod markers in
                    # global/compose flags (-f docker-compose.production.yml) survive.
                    atoms += deobfuscate(shlex.join(inner), lctx + [" ".join(toks)], depth + 1)
                    continue
            atoms.append(Atom(toks, lctx))
    return atoms


def _prod_marked(hay, rules):
    h = hay.lower()
    for m in rules.get("prod_markers", []):
        core = m.strip("*").lower()
        if not core:
            continue
        # Letter-boundary match so `prod` matches db-prod / prod_db / prod1 / prod01
        # / --context prod / *.production.* but NOT substrings like "products" or
        # "delivery" (boundary is letters only, so adjacent digits are allowed).
        if re.search(r'(?<![a-z])' + re.escape(core) + r'(?![a-z])', h):
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


def _entry_match(entry, argv):
    if not _seq_match(argv, entry.get("seq", [])):
        return False
    f = entry.get("flag")
    if f and f not in argv:
        return False
    fa = entry.get("flag_any")
    if fa and not any(x in argv for x in fa):
        return False
    return True


def _is_db_client(atom):
    if atom.argv and os.path.basename(atom.argv[0]) in DB_CLIENTS:
        return True
    # Only heredoc invocation lines (which contain `<<`) name the client out-of-band;
    # transport wrappers do not (the inner command's argv[0] already carries it). This
    # avoids false positives like `docker exec c bash -c "echo psql 'DROP ...'"` whose
    # wrapper context merely mentions psql. Redirect targets are also ignored.
    for c in atom.context:
        if "<<" not in c:
            continue
        toks = c.replace("'", " ").replace('"', " ").split()
        for idx, tok in enumerate(toks):
            if tok[:1] in "<>":
                continue
            if os.path.basename(tok.lstrip("<>&|")) in DB_CLIENTS:
                prev = toks[idx-1] if idx > 0 else ""
                if prev in REDIRECTS:
                    continue
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
        if parts[0] in CRITICAL_ROOTS:
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
    # --- Tier 1: irreversible everywhere -> block always ---
    if atom.argv and os.path.basename(atom.argv[0]) == "rm" and _rm_protected(atom.argv, cwd):
        outcome, reason = OUTCOME_BLOCK, "rm of a protected/irreversible path: " + cmd
    if outcome != OUTCOME_BLOCK:
        for entry in rules.get("tier1_cmd", []):
            if _entry_match(entry, atom.argv):
                outcome, reason = OUTCOME_BLOCK, "irreversible op: " + cmd
                break
    if outcome != OUTCOME_BLOCK:
        for p in rules.get("tier1_regex", []) + rules.get("extra_block", []):
            if re.search(p, cmd, re.I):
                outcome, reason = OUTCOME_BLOCK, "irreversible op: " + cmd
                break
    # --- Tier 2: catastrophic against prod, reversible locally ---
    if outcome != OUTCOME_BLOCK and _prod_marked(hay, rules):
        prod_hit = False
        for entry in rules.get("tier2_cmd", []):
            if _entry_match(entry, atom.argv):
                prod_hit = True
                break
        if not prod_hit:
            for p in rules.get("tier2_sql_regex", []):
                if re.search(p, cmd, re.I) and _is_db_client(atom):
                    prod_hit = True
                    break
        if not prod_hit:
            for p in rules.get("tier2_regex", []):
                if re.search(p, cmd, re.I):
                    prod_hit = True
                    break
        if prod_hit:
            outcome, reason = OUTCOME_BLOCK, "destructive op against production: " + cmd
    # --- Warn: recoverable ---
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
