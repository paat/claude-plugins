#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import shutil
import stat
import subprocess
import tempfile
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
REFRESH = ROOT / "scripts" / "refresh-codex-plugin.sh"
RESOLVE = ROOT / "scripts" / "resolve-codex-plugin-resource.sh"


def write_executable(path: Path, body: str) -> None:
    path.write_text(body, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


def run_fake_regression(tmp: Path) -> None:
    home = tmp / "fake-home"
    cache = home / "plugins/cache/test-market/sample"
    old_locator = cache / "1.0.0/skills/demo/SKILL.md"
    old_locator.parent.mkdir(parents=True)
    old_locator.write_text("version A\n", encoding="utf-8")

    fake = tmp / "codex"
    write_executable(
        fake,
        """#!/usr/bin/env bash
set -euo pipefail
root="$CODEX_HOME/plugins/cache/test-market/sample"
if [ -n "${FAKE_CODEX_STARTED:-}" ]; then printf 'started\\n' > "$FAKE_CODEX_STARTED"; fi
rm -rf "$root"
if [ "${FAKE_CODEX_FAIL:-0}" = 1 ]; then
  mkdir -p "$root/partial/skills/demo"
  printf 'partial\\n' > "$root/partial/skills/demo/SKILL.md"
  exit 9
fi
if [ -n "${FAKE_CODEX_DELAY:-}" ]; then sleep "$FAKE_CODEX_DELAY"; fi
mkdir -p "$root/$FAKE_CODEX_VERSION/skills/demo"
printf 'version %s\\n' "$FAKE_CODEX_VERSION" > "$root/$FAKE_CODEX_VERSION/skills/demo/SKILL.md"
if [ "${FAKE_SHIP_MARKER:-0}" = 1 ]; then printf '0\\n' > "$root/$FAKE_CODEX_VERSION/.codex-retained-at"; fi
""",
    )
    env = os.environ | {
        "CODEX_HOME": str(home),
        "CODEX_BIN": str(fake),
        "FAKE_CODEX_VERSION": "2.0.0",
    }
    refreshed = subprocess.run(
        [str(REFRESH), "sample@test-market"], check=True, env=env, capture_output=True, text=True
    )
    assert "active sessions keep their original locators" in refreshed.stderr
    assert old_locator.read_text(encoding="utf-8") == "version A\n"
    assert (cache / "2.0.0/skills/demo/SKILL.md").is_file()

    env["FAKE_CODEX_FAIL"] = "1"
    failed = subprocess.run([str(REFRESH), "sample@test-market"], env=env)
    assert failed.returncode == 9
    assert old_locator.read_text(encoding="utf-8") == "version A\n"
    assert not (cache / "partial").exists()

    for index in range(12):
        retained = cache / f"0.0.{index}"
        retained.mkdir(parents=True)
        (cache / ".retained").mkdir(exist_ok=True)
        (cache / f".retained/0.0.{index}").write_text(f"{index + 1}\n", encoding="utf-8")
    corrupt = cache / "corrupt"
    corrupt.mkdir()
    (cache / ".retained/corrupt").write_text("invalid\n", encoding="utf-8")
    env.pop("FAKE_CODEX_FAIL")
    env["FAKE_CODEX_VERSION"] = "3.0.0"
    env["CODEX_PLUGIN_RETAIN_SECONDS"] = "9999999999"
    env["CODEX_PLUGIN_RETAIN_MAX"] = "3"
    env["FAKE_SHIP_MARKER"] = "1"
    bounded = subprocess.run(
        [str(REFRESH), "sample@test-market"], check=True, env=env, capture_output=True, text=True
    )
    assert "retention cap is evicting" in bounded.stderr
    assert "resetting invalid retention marker" in bounded.stderr
    retained = list((cache / ".retained").glob("*"))
    assert len(retained) == 3
    assert (cache / "3.0.0/skills/demo/SKILL.md").is_file()

    shutil.rmtree(old_locator.parents[2], ignore_errors=True)
    resolved = subprocess.run(
        [str(RESOLVE), str(old_locator)], check=True, env=env, capture_output=True, text=True
    )
    assert resolved.stdout.strip() == str(cache / "3.0.0/skills/demo/SKILL.md")
    assert "using same-plugin Codex version 3.0.0" in resolved.stderr
    assert "never Claude cache" in resolved.stderr
    traversal = subprocess.run(
        [str(RESOLVE), str(cache / "1.0.0/../../sample/3.0.0/skills/demo/SKILL.md")],
        env=env,
        capture_output=True,
        text=True,
    )
    assert traversal.returncode == 1
    assert "may not contain . or .. segments" in traversal.stderr

    started = tmp / "first-refresh-started"
    first_env = env | {
        "FAKE_CODEX_VERSION": "4.0.0",
        "FAKE_CODEX_DELAY": "0.4",
        "FAKE_CODEX_STARTED": str(started),
        "FAKE_SHIP_MARKER": "0",
    }
    first = subprocess.Popen(
        [str(REFRESH), "sample@test-market"], env=first_env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True
    )
    for _ in range(100):
        if started.exists():
            break
        time.sleep(0.01)
    assert started.exists()
    second_env = env | {"FAKE_CODEX_VERSION": "5.0.0", "FAKE_SHIP_MARKER": "0"}
    second_env.pop("FAKE_CODEX_DELAY", None)
    second_env.pop("FAKE_CODEX_STARTED", None)
    subprocess.run(
        [str(REFRESH), "sample@test-market"], check=True, env=second_env, capture_output=True, text=True
    )
    assert first.wait() == 0
    assert (cache / "5.0.0/skills/demo/SKILL.md").is_file()
    assert (cache / ".retained/4.0.0").is_file()


def run_codex_integration(tmp: Path) -> bool:
    codex = shutil.which("codex")
    if codex is None:
        return False

    home = tmp / "real-home"
    market = tmp / "market"
    plugin = market / "plugins/sample"
    skill = plugin / "skills/demo/SKILL.md"
    (market / ".agents/plugins").mkdir(parents=True)
    home.mkdir()
    (plugin / ".codex-plugin").mkdir(parents=True)
    skill.parent.mkdir(parents=True)
    (market / ".agents/plugins/marketplace.json").write_text(
        json.dumps(
            {
                "name": "test-market",
                "plugins": [
                    {
                        "name": "sample",
                        "source": {"source": "local", "path": "./plugins/sample"},
                        "policy": {"installation": "AVAILABLE", "authentication": "ON_INSTALL"},
                        "category": "Developer Tools",
                    }
                ],
            }
        ),
        encoding="utf-8",
    )
    manifest = {"name": "sample", "version": "1.0.0", "description": "Refresh regression", "skills": "./skills/"}
    manifest_path = plugin / ".codex-plugin/plugin.json"
    manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
    skill.write_text("version A\n", encoding="utf-8")
    env = os.environ | {"CODEX_HOME": str(home), "CODEX_BIN": codex}
    subprocess.run([codex, "plugin", "marketplace", "add", str(market)], check=True, env=env, stdout=subprocess.DEVNULL)
    subprocess.run(
        [str(REFRESH), "sample@test-market"], check=True, env=env, capture_output=True, text=True
    )
    old_locator = home / "plugins/cache/test-market/sample/1.0.0/skills/demo/SKILL.md"
    assert old_locator.read_text(encoding="utf-8") == "version A\n"

    manifest["version"] = "2.0.0"
    manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
    skill.write_text("version B\n", encoding="utf-8")
    refreshed = subprocess.run(
        [str(REFRESH), "sample@test-market"], check=True, env=env, capture_output=True, text=True
    )
    assert "a new thread is required" in refreshed.stderr
    assert old_locator.read_text(encoding="utf-8") == "version A\n"
    new_locator = home / "plugins/cache/test-market/sample/2.0.0/skills/demo/SKILL.md"
    assert new_locator.read_text(encoding="utf-8") == "version B\n"

    shutil.rmtree(old_locator.parents[2])
    resolved = subprocess.run(
        [str(RESOLVE), str(old_locator)], check=True, env=env, capture_output=True, text=True
    )
    assert resolved.stdout.strip() == str(new_locator)
    assert "never Claude cache" in resolved.stderr
    return True


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="codex-plugin-refresh-") as raw_tmp:
        tmp = Path(raw_tmp)
        run_fake_regression(tmp)
        integrated = run_codex_integration(tmp)
    suffix = " including Codex CLI integration" if integrated else " (Codex CLI integration skipped)"
    print(f"refresh-codex-plugin tests passed{suffix}")


if __name__ == "__main__":
    main()
