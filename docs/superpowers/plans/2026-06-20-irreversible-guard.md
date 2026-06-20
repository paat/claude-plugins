# irreversible-guard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a `PreToolUse` plugin that blocks Bash commands with no practical local undo, de-obfuscating transport wrappers (ssh / docker exec), heredocs, command chains, and env prefixes before matching a tiered deny-set.

**Architecture:** A single Python matcher (`hooks/irreversible-guard.py`) is invoked via a thin bash wrapper (`hooks/guard.sh`, fail-open if python3 absent) on every `Bash` tool call. It de-obfuscates the command into "effective atoms," classifies each against a data-driven deny-set (`rules/deny-set.json` + optional `.claude/irreversible-guard.json`), and takes the most severe outcome: BLOCK (exit 2 + stderr), WARN (exit 0 + additionalContext), or PASS (exit 0, silent).

**Tech Stack:** Python 3 (stdlib only — `json`, `re`, `shlex`, `os`, `sys`), bash 4+, Claude Code plugin hooks.

## Global Constraints

- Plugin lives at `plugins/irreversible-guard/` (repo houses plugins under `plugins/`).
- Generic / project-agnostic: NO hardcoded company names, paths, or stacks. All project-specific tuning goes through `.claude/irreversible-guard.json` or `rules/deny-set.json` data — never code.
- Python stdlib only — no pip dependencies (no PyYAML, no pytest). Tests use the stdlib `unittest` module and a bash integration harness.
- python3 documented as a prerequisite in the README; the hook fails **open** (exit 0) if python3 is missing.
- Bump version in BOTH `plugins/irreversible-guard/.claude-plugin/plugin.json` AND root `.claude-plugin/marketplace.json`; add the new plugin entry to `marketplace.json`.
- README MUST include the three-scope Installation section (user / project / local).
- Hook output contract: BLOCK = `exit 2` + reason on stderr; WARN = `exit 0` + JSON `{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"…"}}` on stdout; PASS = `exit 0`, no output.
- Work on branch `feat/irreversible-guard` (already created; the design spec is committed there).

---

### Task 1: Plugin scaffold + manifest + marketplace entry

**Files:**
- Create: `plugins/irreversible-guard/.claude-plugin/plugin.json`
- Create: `plugins/irreversible-guard/hooks/hooks.json`
- Create: `plugins/irreversible-guard/hooks/guard.sh`
- Modify: `.claude-plugin/marketplace.json` (append plugin entry)

**Interfaces:**
- Produces: the plugin directory, the `PreToolUse` → `bash guard.sh` wiring, and the marketplace registration that later tasks build on. `guard.sh` execs `python3 "${CLAUDE_PLUGIN_ROOT}/hooks/irreversible-guard.py"` (created in Task 3).

- [ ] **Step 1: Create the plugin manifest**

Create `plugins/irreversible-guard/.claude-plugin/plugin.json`:

```json
{
  "name": "irreversible-guard",
  "version": "0.1.0",
  "description": "PreToolUse gate that blocks Bash commands with no practical local undo — de-obfuscates ssh/docker-exec transports, heredocs, command chains, and env prefixes, then matches a tiered deny-set (irreversible-everywhere ops block unconditionally; locally-reversible ops block only when the command names production)",
  "author": {
    "name": "Andre Paat"
  },
  "repository": "https://github.com/paat/claude-plugins",
  "license": "MIT",
  "keywords": ["pretooluse", "guardrail", "irreversible", "deny-list", "blast-radius", "rm-rf", "terraform-destroy", "drop-table", "safety"]
}
```

- [ ] **Step 2: Create the hook wiring**

Create `plugins/irreversible-guard/hooks/hooks.json`:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "bash \"${CLAUDE_PLUGIN_ROOT}/hooks/guard.sh\"",
            "timeout": 10
          }
        ]
      }
    ]
  }
}
```

- [ ] **Step 3: Create the fail-open wrapper**

Create `plugins/irreversible-guard/hooks/guard.sh`. The wrapper checks for python3 and `exec`s the matcher so its exit code (2 for BLOCK) is preserved — a `&&`/`||` chain would swallow exit 2, so a script with `exec` is required:

```bash
#!/usr/bin/env bash
# irreversible-guard PreToolUse wrapper. Fails OPEN (exit 0) if python3 is absent
# so a missing interpreter never bricks every Bash tool call. exec preserves the
# matcher's exit code (2 = block).
set -uo pipefail

if ! command -v python3 >/dev/null 2>&1; then
  echo "[irreversible-guard] python3 not found; guard disabled (fail-open)" >&2
  exit 0
fi

exec python3 "${CLAUDE_PLUGIN_ROOT}/hooks/irreversible-guard.py"
```

- [ ] **Step 4: Register in the marketplace**

In `.claude-plugin/marketplace.json`, append this object to the `plugins` array (mirror the existing entries' shape — `name`, `description`, `version`, `author`, `source`, `category`, `homepage`):

```json
{
  "name": "irreversible-guard",
  "description": "PreToolUse gate that blocks Bash commands with no practical local undo — de-obfuscates ssh/docker-exec transports, heredocs, chains, and env prefixes before matching a tiered deny-set",
  "version": "0.1.0",
  "author": {
    "name": "Andre Paat"
  },
  "source": "./plugins/irreversible-guard",
  "category": "security",
  "homepage": "https://github.com/paat/claude-plugins"
}
```

- [ ] **Step 5: Verify JSON validity and wiring**

Run:
```bash
python3 -m json.tool plugins/irreversible-guard/.claude-plugin/plugin.json >/dev/null && echo plugin-ok
python3 -m json.tool plugins/irreversible-guard/hooks/hooks.json >/dev/null && echo hooks-ok
python3 -m json.tool .claude-plugin/marketplace.json >/dev/null && echo marketplace-ok
python3 -c "import json;assert any(p['name']=='irreversible-guard' for p in json.load(open('.claude-plugin/marketplace.json'))['plugins']);print('registered-ok')"
bash -n plugins/irreversible-guard/hooks/guard.sh && echo guard-syntax-ok
```
Expected: `plugin-ok`, `hooks-ok`, `marketplace-ok`, `registered-ok`, `guard-syntax-ok`.

- [ ] **Step 6: Commit**

```bash
git add plugins/irreversible-guard/.claude-plugin/plugin.json plugins/irreversible-guard/hooks/hooks.json plugins/irreversible-guard/hooks/guard.sh .claude-plugin/marketplace.json
git commit -m "feat(irreversible-guard): scaffold plugin manifest, hook wiring, marketplace entry"
```

---

### Task 2: Default deny-set data file

**Files:**
- Create: `plugins/irreversible-guard/rules/deny-set.json`
- Test: `plugins/irreversible-guard/tests/test_rules.py`

**Interfaces:**
- Produces: `rules/deny-set.json` — the authoritative tiered pattern set, loaded by `load_rules()` in Task 3. Keys: `tier1_regex`, `tier2_regex`, `warn_regex`, `prod_markers`, `allow`, `extra_block`, `warn_only` (all lists of strings).

- [ ] **Step 1: Write the failing test**

Create `plugins/irreversible-guard/tests/test_rules.py`:

```python
import json, os, re, unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RULES_PATH = os.path.join(ROOT, "rules", "deny-set.json")


class TestRules(unittest.TestCase):
    def setUp(self):
        with open(RULES_PATH) as f:
            self.rules = json.load(f)

    def test_required_keys_present_and_lists(self):
        for k in ("tier1_regex", "tier2_regex", "warn_regex", "prod_markers",
                  "allow", "extra_block", "warn_only"):
            self.assertIn(k, self.rules)
            self.assertIsInstance(self.rules[k], list)

    def test_all_regexes_compile(self):
        for k in ("tier1_regex", "tier2_regex", "warn_regex"):
            for pat in self.rules[k]:
                re.compile(pat)  # raises if invalid

    def test_seeds_present(self):
        t1 = " ".join(self.rules["tier1_regex"])
        self.assertIn("destroy", t1)
        t2 = " ".join(self.rules["tier2_regex"])
        self.assertIn("DROP", t2)


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd plugins/irreversible-guard && python3 -m unittest tests.test_rules -v`
Expected: FAIL — `FileNotFoundError` (deny-set.json does not exist yet).

- [ ] **Step 3: Create the deny-set data file**

Create `plugins/irreversible-guard/rules/deny-set.json`:

```json
{
  "tier1_regex": [
    "\\b(terraform|tofu)\\s+destroy\\b",
    "\\bdd\\b[^\\n]*\\bof=/dev/",
    "\\bmkfs(\\.\\w+)?\\b",
    "\\bwipefs\\b",
    "\\b(fly|flyctl)\\s+volumes\\s+destroy\\b",
    "\\brailway\\s+volume\\s+delete\\b",
    "\\baws\\s+s3\\s+rb\\b",
    "\\baws\\s+s3\\s+rm\\b[^\\n]*--recursive",
    "\\baws\\s+ec2\\s+delete-volume\\b",
    "\\baws\\s+rds\\s+delete-db-(instance|cluster)\\b",
    "\\bgcloud\\s+sql\\s+instances\\s+delete\\b",
    "\\bgcloud\\s+compute\\s+disks\\s+delete\\b",
    "\\bheroku\\s+pg:reset\\b",
    "\\bkubectl\\s+delete\\s+(namespace|ns|pv|pvc)\\b"
  ],
  "tier2_regex": [
    "\\bDROP\\s+(TABLE|DATABASE)\\b",
    "\\bTRUNCATE\\b",
    "\\bef\\s+database\\s+drop\\b",
    "\\bdocker\\s+compose\\b[^\\n]*\\bdown\\b[^\\n]*(--volumes|\\s-v\\b)",
    "\\bdocker\\s+volume\\s+(rm|prune)\\b"
  ],
  "warn_regex": [
    "\\bgit\\s+push\\b[^\\n]*(--force\\b|--force-with-lease\\b|\\s-f\\b)",
    "\\bgit\\s+reset\\s+--hard\\b",
    "\\bgit\\s+clean\\s+-\\w*[fd]\\w*"
  ],
  "prod_markers": ["*prod*", "*production*", "*-live"],
  "allow": [],
  "extra_block": [],
  "warn_only": []
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd plugins/irreversible-guard && python3 -m unittest tests.test_rules -v`
Expected: PASS (3 tests OK).

- [ ] **Step 5: Commit**

```bash
git add plugins/irreversible-guard/rules/deny-set.json plugins/irreversible-guard/tests/test_rules.py
git commit -m "feat(irreversible-guard): tiered deny-set data + schema test"
```

---

### Task 3: The de-obfuscating matcher

This is the core. The full implementation below is already verified against a 30-case matrix plus exit-code/fail-open integration checks; transcribe it exactly.

**Files:**
- Create: `plugins/irreversible-guard/hooks/irreversible-guard.py`
- Test: `plugins/irreversible-guard/tests/test_matcher.py`

**Interfaces:**
- Consumes: `rules/deny-set.json` (Task 2) via `load_rules(plugin_root, cwd)`.
- Produces (importable):
  - `classify(command: str, rules: dict, cwd: str) -> (outcome: str, reason: str)` where outcome ∈ {`"BLOCK"`, `"WARN"`, `"PASS"`}.
  - `deobfuscate(cmd: str, context=None, depth=0) -> list[Atom]` where `Atom = namedtuple("Atom", ["argv", "context"])`.
  - `load_rules(plugin_root: str, cwd: str) -> dict`.
  - `DEFAULT_RULES: dict` (inline fallback mirroring deny-set.json).
  - `main() -> int` (stdin payload → exit code; prints WARN JSON to stdout, BLOCK reason to stderr).
  - Constants `OUTCOME_BLOCK`, `OUTCOME_WARN`, `OUTCOME_PASS`.

- [ ] **Step 1: Write the failing test**

Create `plugins/irreversible-guard/tests/test_matcher.py`:

```python
import importlib.util, os, unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_spec = importlib.util.spec_from_file_location(
    "ig", os.path.join(ROOT, "hooks", "irreversible-guard.py"))
ig = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ig)

CWD = "/repo"
RULES = ig.DEFAULT_RULES


def classify(cmd):
    return ig.classify(cmd, RULES, CWD)[0]


class TestBlockAlways(unittest.TestCase):
    def test_rm_dangerous_roots(self):
        for cmd in ("rm -rf /", "rm -rf ~", "rm -rf $HOME",
                    "rm -rf /opt/aruannik/data/*", "rm -rf --no-preserve-root /x",
                    "DEBUG=true rm -rf /", "cd /tmp && rm -rf /"):
            self.assertEqual(classify(cmd), "BLOCK", cmd)

    def test_disk_and_iac_and_cloud(self):
        for cmd in ("dd if=/dev/zero of=/dev/sda", "mkfs.ext4 /dev/sdb", "wipefs -a /dev/sda",
                    "terraform destroy", "ENV=x tofu destroy -auto-approve",
                    "fly volumes destroy vol_123", "railway volume delete",
                    "aws s3 rb s3://b --force", "aws s3 rm s3://b --recursive",
                    "aws rds delete-db-instance --db-instance-identifier x",
                    "gcloud sql instances delete x", "heroku pg:reset",
                    "kubectl delete namespace prod"):
            self.assertEqual(classify(cmd), "BLOCK", cmd)


class TestTransportWrapped(unittest.TestCase):
    def test_ssh_and_docker_to_prod(self):
        for cmd in ("ssh aruannik-live 'rm -rf /opt/aruannik/data/*'",
                    "ssh db-prod \"psql x -c 'DROP TABLE users'\"",
                    "docker exec varustame-prod-api psql d -c 'DROP TABLE annetused'",
                    "docker compose -f docker-compose.production.yml down -v",
                    "ssh db-prod 'psql x <<EOF\nDROP TABLE users;\nEOF'"):
            self.assertEqual(classify(cmd), "BLOCK", cmd)


class TestTier2LocalIsPass(unittest.TestCase):
    def test_local_reversible_pass(self):
        for cmd in ("psql \"$DB\" -c 'DROP TABLE users'", "docker compose down -v",
                    "dotnet ef database drop", "psql local <<EOF\nDROP TABLE t;\nEOF",
                    "docker volume prune"):
            self.assertEqual(classify(cmd), "PASS", cmd)


class TestFalsePositiveGuards(unittest.TestCase):
    def test_routine_pass(self):
        for cmd in ("rm -rf node_modules", "rm -rf .next", "rm -rf build dist",
                    "rm -rf bin obj", "git push origin main", "npm ci",
                    "dotnet ef database update", "echo hi"):
            self.assertEqual(classify(cmd), "PASS", cmd)


class TestWarn(unittest.TestCase):
    def test_recoverable_warn(self):
        for cmd in ("git push --force origin main", "git push -f",
                    "git reset --hard HEAD~3", "git clean -fdx"):
            self.assertEqual(classify(cmd), "WARN", cmd)


class TestConfigBehaviour(unittest.TestCase):
    def test_allow_overrides_block(self):
        rules = dict(ig.DEFAULT_RULES, allow=["rm -rf /"])
        self.assertEqual(ig.classify("rm -rf /", rules, CWD)[0], "PASS")

    def test_warn_only_downgrades_block(self):
        rules = dict(ig.DEFAULT_RULES, warn_only=["terraform destroy"])
        self.assertEqual(ig.classify("terraform destroy", rules, CWD)[0], "WARN")

    def test_extra_block_adds_pattern(self):
        rules = dict(ig.DEFAULT_RULES, extra_block=[r"\bnpm\s+publish\b"])
        self.assertEqual(ig.classify("npm publish", rules, CWD)[0], "BLOCK")


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd plugins/irreversible-guard && python3 -m unittest tests.test_matcher -v`
Expected: FAIL — `FileNotFoundError` / module load error (irreversible-guard.py does not exist yet).

- [ ] **Step 3: Write the matcher**

Create `plugins/irreversible-guard/hooks/irreversible-guard.py` with exactly this content:

```python
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

DEFAULT_RULES = {
 "tier1_regex": [
   r'\b(terraform|tofu)\s+destroy\b', r'\bdd\b[^\n]*\bof=/dev/', r'\bmkfs(\.\w+)?\b', r'\bwipefs\b',
   r'\b(fly|flyctl)\s+volumes\s+destroy\b', r'\brailway\s+volume\s+delete\b', r'\baws\s+s3\s+rb\b',
   r'\baws\s+s3\s+rm\b[^\n]*--recursive', r'\baws\s+ec2\s+delete-volume\b',
   r'\baws\s+rds\s+delete-db-(instance|cluster)\b', r'\bgcloud\s+sql\s+instances\s+delete\b',
   r'\bgcloud\s+compute\s+disks\s+delete\b', r'\bheroku\s+pg:reset\b',
   r'\bkubectl\s+delete\s+(namespace|ns|pv|pvc)\b'],
 "tier2_regex": [
   r'\bDROP\s+(TABLE|DATABASE)\b', r'\bTRUNCATE\b', r'\bef\s+database\s+drop\b',
   r'\bdocker\s+compose\b[^\n]*\bdown\b[^\n]*(--volumes|\s-v\b)', r'\bdocker\s+volume\s+(rm|prune)\b'],
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


def _is_protected_target(t, cwd):
    raw = t
    if raw in ("/", "~", "~/", "$HOME", "${HOME}", "*", ".*", "./*",
               "~/*", "$HOME/*", "${HOME}/*"):
        return True
    exp = os.path.expanduser(raw.replace("${HOME}", "~").replace("$HOME", "~"))
    home = os.path.normpath(os.path.expanduser("~"))
    if os.path.isabs(exp):
        norm = os.path.normpath(exp); parts = [p for p in norm.split("/") if p]
        if norm == "/" or len(parts) == 1:
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
            return re.search(p[1:-1], text) is not None
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
        for p in rules.get("tier1_regex", []) + rules.get("extra_block", []):
            if re.search(p, cmd):
                outcome, reason = OUTCOME_BLOCK, "irreversible op: " + cmd
                break
    if outcome != OUTCOME_BLOCK:
        for p in rules.get("tier2_regex", []):
            if re.search(p, cmd):
                if _prod_marked(hay, rules):
                    outcome, reason = OUTCOME_BLOCK, "destructive op against production: " + cmd
                break
    if outcome == OUTCOME_PASS:
        for p in rules.get("warn_regex", []):
            if re.search(p, cmd):
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd plugins/irreversible-guard && python3 -m unittest tests.test_matcher -v`
Expected: PASS (all test methods OK across the 6 test classes).

- [ ] **Step 5: Commit**

```bash
git add plugins/irreversible-guard/hooks/irreversible-guard.py plugins/irreversible-guard/tests/test_matcher.py
git commit -m "feat(irreversible-guard): de-obfuscating tiered matcher + unit tests"
```

---

### Task 4: Integration harness (real exit codes through the wrapper)

**Files:**
- Create: `plugins/irreversible-guard/tests/cases.tsv`
- Create: `plugins/irreversible-guard/tests/run.sh`

**Interfaces:**
- Consumes: `hooks/guard.sh` (Task 1), `hooks/irreversible-guard.py` (Task 3), `rules/deny-set.json` (Task 2).
- Produces: `tests/run.sh` — exits non-zero on any mismatch; the project-wide green/red proof. Each row of `cases.tsv` is `command <TAB> expected(BLOCK|WARN|PASS)`; the runner feeds a synthetic `PreToolUse` payload to the wrapper and maps exit code 2 → BLOCK, `"additionalContext"` on stdout → WARN, else PASS.

- [ ] **Step 1: Write the fixtures**

Create `plugins/irreversible-guard/tests/cases.tsv` (tab-separated; lines starting with `#` are comments). Use literal tabs between the command and the expected outcome:

```
# Tier 1 — block always
rm -rf /	BLOCK
rm -rf ~	BLOCK
rm -rf $HOME	BLOCK
rm -rf /opt/app/data/*	BLOCK
dd if=/dev/zero of=/dev/sda	BLOCK
terraform destroy	BLOCK
ENV=x tofu destroy -auto-approve	BLOCK
fly volumes destroy vol_1	BLOCK
railway volume delete	BLOCK
aws s3 rb s3://b --force	BLOCK
kubectl delete namespace prod	BLOCK
DEBUG=true rm -rf /	BLOCK
cd /tmp && rm -rf /	BLOCK
# Transport-wrapped → block (prod)
ssh app-live 'rm -rf /opt/app/data/*'	BLOCK
docker exec api-prod psql d -c 'DROP TABLE t'	BLOCK
docker compose -f docker-compose.production.yml down -v	BLOCK
# Tier 2 local → pass (reversible)
psql "$DB" -c 'DROP TABLE t'	PASS
docker compose down -v	PASS
dotnet ef database drop	PASS
# False-positive guards → pass
rm -rf node_modules	PASS
rm -rf .next	PASS
rm -rf build dist	PASS
git push origin main	PASS
npm ci	PASS
dotnet ef database update	PASS
# Warn — recoverable
git push --force origin main	WARN
git reset --hard HEAD~3	WARN
git clean -fdx	WARN
```

- [ ] **Step 2: Write the runner**

Create `plugins/irreversible-guard/tests/run.sh`:

```bash
#!/usr/bin/env bash
# Integration test: feed synthetic PreToolUse payloads through the real wrapper
# and assert the mapped outcome. Exit non-zero on any mismatch.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
export CLAUDE_PLUGIN_ROOT="$(dirname "$HERE")"
HOOK="$CLAUDE_PLUGIN_ROOT/hooks/guard.sh"

pass=0; fail=0
while IFS=$'\t' read -r cmd expected; do
  [[ -z "${cmd:-}" || "$cmd" == \#* ]] && continue
  payload="$(CMD="$cmd" python3 -c 'import json,os;print(json.dumps({"tool_name":"Bash","tool_input":{"command":os.environ["CMD"]},"cwd":os.getcwd()}))')"
  out="$(printf '%s' "$payload" | bash "$HOOK" 2>/dev/null)"; code=$?
  if [[ $code -eq 2 ]]; then actual=BLOCK
  elif printf '%s' "$out" | grep -q '"additionalContext"'; then actual=WARN
  else actual=PASS; fi
  if [[ "$actual" == "$expected" ]]; then
    pass=$((pass+1))
  else
    fail=$((fail+1)); echo "MISMATCH [want=$expected got=$actual]: $cmd"
  fi
done < "$HERE/cases.tsv"

echo "pass=$pass fail=$fail"
[[ $fail -eq 0 ]]
```

- [ ] **Step 3: Run the integration harness**

Run: `bash plugins/irreversible-guard/tests/run.sh`
Expected: a `pass=28 fail=0` line (count matches non-comment rows) and exit status 0.

- [ ] **Step 4: Commit**

```bash
git add plugins/irreversible-guard/tests/cases.tsv plugins/irreversible-guard/tests/run.sh
git commit -m "test(irreversible-guard): fixture-driven exit-code integration harness"
```

---

### Task 5: README + version sync + final verification

**Files:**
- Create: `plugins/irreversible-guard/README.md`
- Verify: full test suite + JSON validity

**Interfaces:**
- Consumes: everything from Tasks 1–4.
- Produces: end-user documentation (incl. the three-scope Installation section, python3 prerequisite, config schema, deny-set tiers) and a final all-green verification.

- [ ] **Step 1: Write the README**

Create `plugins/irreversible-guard/README.md`:

````markdown
# irreversible-guard

A `PreToolUse` gate that blocks Bash commands with **no practical local undo** before they run.
Agents occasionally execute genuinely catastrophic, irreversible operations — "prompts are not
permissions." A `DO-NOT` line in a rules file does not bind a long-context agent; enforcement has to
live in a hook. This plugin is that hook, scoped **deliberately to irreversible blast-radius only** —
reversible risk is left alone, so it is not friction you disable by Thursday.

## What it does

On every `Bash` tool call it de-obfuscates the command — unwrapping heredocs, splitting on
`&&`/`||`/`;`/`|`, stripping `VAR=value` prefixes, and **recursing through transport wrappers**
(`ssh host '…'`, `docker exec <ctr> …`, `docker compose … exec`, `bash -c`, `eval`) — then matches
each resulting sub-command against a tiered deny-set:

- **Tier 1 — blocked always** (irreversible in every environment): `rm -rf` of protected roots
  (`/`, `~`/`$HOME`, the repo root, `/opt`,`/srv`,`/data`,`/var/lib`, `..`-escapes,
  `--no-preserve-root`); `dd of=/dev/…`, `mkfs`, `wipefs`; `terraform/tofu destroy`; cloud volume/DB
  delete verbs (`fly volumes destroy`, `railway volume delete`, `aws s3 rb`, `aws ec2 delete-volume`,
  `aws rds delete-db-instance`, `gcloud sql instances delete`, `gcloud compute disks delete`,
  `heroku pg:reset`, `kubectl delete namespace|pv|pvc`).
- **Tier 2 — blocked only when the command names production** (catastrophic against prod, routine
  and reversible locally): `DROP TABLE`/`DROP DATABASE`/`TRUNCATE`/`dotnet ef database drop` via a DB
  client; `docker compose down -v`, `docker volume rm|prune`. The "prod marker" is explicit in the
  command — a transport host/container/compose-file/connection string matching `*prod*`,
  `*production*`, or `*-live` (configurable). No prod marker → treated as local & reversible → allowed.
- **Warn (non-blocking)**: `git push --force`/`--force-with-lease`, `git reset --hard`,
  `git clean -fdx` — recoverable, so they proceed with a caution note.

Outcomes: **BLOCK** → the tool call is denied (exit 2) and the reason is fed back to the agent so it
self-corrects; **WARN** → a caution is added to context and the call proceeds; **PASS** → silent.

## Requirements

- **python3** (stdlib only — no pip packages). If python3 is absent the guard **fails open** (allows
  the command) rather than bricking every Bash call.
- bash 4+.

## Installation

Add this marketplace, then install the plugin at the scope you want:

- **Install for you** (user scope) — available in all your projects:
  `/plugin install irreversible-guard@paat-plugins`
- **Install for all collaborators on this repository** (project scope) — committed to the repo and
  shared with your team via `.claude/settings.json`.
- **Install for you, in this repo only** (local scope) — just you, just this repository, via
  `.claude/settings.local.json`.

## Configuration (optional)

Create `.claude/irreversible-guard.json` in a project to tune behavior:

```json
{
  "allow":        ["rm -rf /var/lib/myapp/scratch", "/terraform\\s+destroy.*-target=module.dev/"],
  "extra_block":  ["\\bnpm\\s+publish\\b"],
  "prod_markers": ["*prod*", "*production*", "*-live", "my-prod-host"],
  "warn_only":    ["terraform destroy"]
}
```

- **`allow`** (highest precedence) — patterns never blocked; your escape hatch for a false positive.
  A value wrapped in `/…/` is a regex; otherwise it is a substring match.
- **`extra_block`** — additional always-block (Tier 1) regex patterns, e.g. project-specific cloud
  delete verbs.
- **`prod_markers`** — substrings (leading/trailing `*` are ignored) that mark a Tier-2 op as
  production-bound. Overrides the defaults.
- **`warn_only`** — downgrade a would-be block to a warning.

Defaults live as data in `rules/deny-set.json` and can be edited directly when vendoring the plugin.

## Testing

```bash
cd plugins/irreversible-guard
python3 -m unittest discover -s tests -v   # unit tests (matcher + rules schema)
bash tests/run.sh                          # integration: real exit codes through the hook
```
````

- [ ] **Step 2: Run the full test suite**

Run:
```bash
cd plugins/irreversible-guard && python3 -m unittest discover -s tests -v && bash tests/run.sh
```
Expected: all unit tests OK; `pass=28 fail=0`; overall exit 0.

- [ ] **Step 3: Confirm version sync**

Run:
```bash
cd /mnt/data/ai/claude-plugins
python3 -c "import json;a=json.load(open('plugins/irreversible-guard/.claude-plugin/plugin.json'))['version'];b=[p for p in json.load(open('.claude-plugin/marketplace.json'))['plugins'] if p['name']=='irreversible-guard'][0]['version'];print('versions',a,b);assert a==b=='0.1.0'"
```
Expected: `versions 0.1.0 0.1.0` and no assertion error.

- [ ] **Step 4: Commit**

```bash
git add plugins/irreversible-guard/README.md
git commit -m "docs(irreversible-guard): README with install, config, and deny-set tiers"
```

---

## Self-Review

**Spec coverage:**
- Bar / criterion (no practical local undo) → Tasks 2–3 (tiers + rm logic). ✓
- De-obfuscation (heredoc, chain, env-prefix, transport recursion) → Task 3 `deobfuscate` + tests. ✓
- Tier 1 block-always set → Task 2 `tier1_regex` + Task 3 `_rm_protected`; tested Task 3/4. ✓
- Tier 2 prod-marker gating → Task 3 `_prod_marked`; tested Task 3/4. ✓
- WARN set → Task 2 `warn_regex`; tested Task 3/4. ✓
- Config (`allow`/`extra_block`/`prod_markers`/`warn_only`) → Task 3 `load_rules`/`classify_atom`; tested Task 3; documented Task 5. ✓
- Output contract (exit 2 / additionalContext / silent) → Task 3 `main`; verified Task 4. ✓
- Fail-open on missing python3 / malformed payload → Task 1 `guard.sh` + Task 3 `main`. ✓
- Plugin layout, manifest, marketplace + version sync → Tasks 1, 5. ✓
- README 3-scope install + python3 prerequisite → Task 5. ✓
- Circuit-breaker explicitly out of scope → not implemented (correct). ✓

**Placeholder scan:** none — every code/step contains complete content.

**Type consistency:** `classify(cmd, rules, cwd) -> (outcome, reason)`, `deobfuscate(...) -> [Atom]`,
`load_rules(plugin_root, cwd) -> dict`, outcome constants `BLOCK/WARN/PASS` are used consistently
across Tasks 3–5 and both test files.
