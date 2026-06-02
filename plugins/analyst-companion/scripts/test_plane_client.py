import json
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).parent


def test_build_payload_minimal():
    from plane_client import build_payload
    p = build_payload(name="Lisa eksport-nupp", description_html="<p>klient soovib</p>",
                       priority="high")
    assert p == {"name": "Lisa eksport-nupp",
                 "description_html": "<p>klient soovib</p>",
                 "priority": "high"}


def test_build_payload_omits_empty_fields():
    from plane_client import build_payload
    p = build_payload(name="X", description_html="", priority=None)
    assert p == {"name": "X"}


def test_cli_dry_run_prints_payload(tmp_path):
    desc = tmp_path / "d.html"; desc.write_text("<p>hi</p>", encoding="utf-8")
    out = subprocess.check_output(
        [sys.executable, str(HERE / "plane_client.py"), "create",
         "--workspace", "ws", "--project", "proj-uuid",
         "--name", "Test item", "--description-html-file", str(desc),
         "--priority", "medium", "--dry-run"],
        text=True, env={"PLANE_API_TOKEN": "x", "PLANE_BASE_URL": "https://plan.r-53.com", "PATH": ""},
    )
    payload = json.loads(out)
    assert payload["name"] == "Test item"
    assert payload["description_html"] == "<p>hi</p>"
    assert payload["priority"] == "medium"
