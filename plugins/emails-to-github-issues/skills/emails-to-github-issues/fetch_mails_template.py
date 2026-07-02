#!/usr/bin/env python3
"""
Ready-to-adapt template: fetch mails from named senders via Proton Bridge
(127.0.0.1:1143 STARTTLS), strip HTML + quoted replies, group into threads,
emit /tmp/mails.json and /tmp/mail_attachments/ with a per-thread manifest.

Usage:
    IMAP_USER='you@example.com' BRIDGE_PASS='...' python3 fetch_mails_template.py
    python3 fetch_mails_template.py --commit-cursor   # after the fetched mail is handled

Edit the CONFIG block below (SENDER_TOKENS, SINCE). Searches are ASCII-only
(imaplib limitation) — pass substrings of the address (e.g. "mueller"), not
display names ("Müller").

Docker networking note (agent in a separate container from the bridge):
127.0.0.1:114x is the *bridge host's* loopback. If this script runs in a
different container than Proton Bridge, that loopback refuses the connection
even though `docker ps` shows the port mapped — the published-port remap only
exists on the docker host, not inside your container. Reach the bridge over
the shared docker network instead: set IMAP_HOST to the bridge container's
docker DNS name and IMAP_PORT=143 (the real in-container port, *not* the
host-published 1143/1144). The container IP works too but isn't stable across
stack recreation — prefer the DNS name.

Unattended runs use a cursor (CURSOR_FILE): last synced date + the Message-IDs
already handled. The fetch searches only mail since that date, drops anything
already in the persisted set, and if nothing new comes back prints a one-line
summary and exits before writing any output files — callers (e.g. an
autonomous SKILL workflow) should treat that as a no-op and skip
repo-convention discovery, artifact generation, and GitHub calls. The fetch
itself never writes the cursor: after the fetched mail has actually been
handled (issues filed/appended, or explicitly classified as no-action), run
`python3 fetch_mails_template.py --commit-cursor` to mark it processed. A
downstream failure before that step leaves the cursor untouched, so the next
run refetches the same messages instead of silently skipping them.
"""

import email
import hashlib
import imaplib
import json
import os
import re
import sys
from datetime import date
from email.header import decode_header, make_header
from html.parser import HTMLParser

# ---- CONFIG ----------------------------------------------------------------

# Checked in main() — `--commit-cursor` needs no credentials.
USER = os.environ.get("IMAP_USER")
PASS = os.environ.get("BRIDGE_PASS")
# Defaults assume the bridge host's loopback; separate-container setups: see docstring.
HOST = os.environ.get("IMAP_HOST", "127.0.0.1")
PORT = int(os.environ.get("IMAP_PORT", "1143"))  # primary proton-bridge; secondary accounts use other ports (e.g. 1144)

# IMAP SEARCH tokens — ASCII substrings of email addresses, not display names
SENDER_TOKENS = ["acme", "globex"]
SINCE = "20-Apr-2026"  # dd-Mon-yyyy — fallback used only on the very first run (no cursor file yet)
MAILBOX = "INBOX"

# Unattended-run cursor: {"last_date": "dd-Mon-yyyy", "message_ids": [...]}. See docstring.
CURSOR_FILE = os.environ.get("MAIL_CURSOR_FILE", ".mail-issue-drafts/cursor.json")

OUT_MAILS = "/tmp/mails.json"
OUT_ATTACH_DIR = "/tmp/mail_attachments"
OUT_MANIFEST = "/tmp/attachments_manifest.json"


# ---- HELPERS ---------------------------------------------------------------

def decode(v):
    if v is None:
        return ""
    return str(make_header(decode_header(v)))


class HTMLText(HTMLParser):
    def __init__(self):
        super().__init__()
        self.out, self.skip = [], 0

    def handle_starttag(self, tag, attrs):
        if tag in ("style", "script", "head"):
            self.skip += 1
        if tag in ("br", "p", "div", "tr", "li"):
            self.out.append("\n")

    def handle_endtag(self, tag):
        if tag in ("style", "script", "head"):
            self.skip = max(0, self.skip - 1)
        if tag in ("p", "div", "tr", "li"):
            self.out.append("\n")

    def handle_data(self, d):
        if not self.skip:
            self.out.append(d)

    def text(self):
        s = "".join(self.out)
        s = re.sub(r"[ \t]+\n", "\n", s)
        s = re.sub(r"\n{3,}", "\n\n", s)
        return s.strip()


def decode_part(part):
    payload = part.get_payload(decode=True)
    if not payload:
        return ""
    return payload.decode(part.get_content_charset() or "utf-8", "replace")


def extract_body(msg):
    plain, html, attachments = [], [], []
    parts = msg.walk() if msg.is_multipart() else [msg]
    for part in parts:
        ctype = part.get_content_type()
        disp = str(part.get("Content-Disposition") or "")
        fn = part.get_filename()
        if ctype.startswith("image/") and ("attachment" in disp or "inline" in disp or fn):
            payload = part.get_payload(decode=True)
            if payload:
                attachments.append({"filename": decode(fn) if fn else f"inline{ctype}",
                                    "payload": payload, "ctype": ctype})
            continue
        if "attachment" in disp or fn:
            continue
        if ctype == "text/plain":
            plain.append(decode_part(part))
        elif ctype == "text/html":
            html.append(decode_part(part))
    text = "\n\n".join(p for p in plain if p.strip()).strip()
    if not text and html:
        p = HTMLText()
        p.feed("\n\n".join(html))
        text = p.text()
    return text, attachments


QUOTE_STOPS = (
    re.compile(r"^(From|Saatja|Kellelt|De|Von):\s"),
    re.compile(r"^On .* wrote:\s*$"),
    re.compile(r"^-----\s*Original Message\s*-----\s*$"),
)


def strip_quoted(text):
    out = []
    for ln in text.splitlines():
        s = ln.strip()
        if any(r.match(s) for r in QUOTE_STOPS):
            break
        if s.startswith(">"):
            continue
        out.append(ln)
    return "\n".join(out).strip()


def thread_key(subject, frm):
    """Customer numbering (#NN) wins; else normalized subject. Adapt as needed."""
    s = re.sub(r"^(re:|fwd:|vs:)\s*", "", subject.strip(), flags=re.I).strip()
    m = re.search(r"#\s*(\d+)", s)
    if m:
        return f"num-{int(m.group(1)):05d}"
    sender = "unknown"
    low_frm = (frm or "").lower()
    for tok in SENDER_TOKENS:
        if tok in low_frm:
            sender = tok
            break
    slug = re.sub(r"[^a-z0-9]+", "-", s.lower())[:40].strip("-") or "thread"
    return f"{sender}-{slug}"


# IMAP date tokens must be English regardless of locale — never strftime("%b").
IMAP_MONTHS = ("Jan", "Feb", "Mar", "Apr", "May", "Jun",
               "Jul", "Aug", "Sep", "Oct", "Nov", "Dec")


def imap_today():
    t = date.today()
    return f"{t.day:02d}-{IMAP_MONTHS[t.month - 1]}-{t.year}"


def load_cursor():
    if not os.path.exists(CURSOR_FILE):
        return {"last_date": None, "message_ids": []}
    with open(CURSOR_FILE) as f:
        return json.load(f)


def save_cursor(message_ids):
    today = imap_today()
    prev = load_cursor()
    ids = set(message_ids)
    if prev["last_date"] == today:
        # Same-day runs: earlier IDs are still inside the new SINCE window — keep them.
        # IDs from older dates can't reappear under SINCE=today, so they are pruned.
        ids |= set(prev["message_ids"])
    d = os.path.dirname(CURSOR_FILE)
    if d:
        os.makedirs(d, exist_ok=True)
    with open(CURSOR_FILE, "w") as f:
        json.dump({"last_date": today, "message_ids": sorted(ids)}, f, indent=2)


def commit_cursor():
    """Mark the last fetch as processed. Run only after issues are filed/appended
    (or the batch is explicitly classified no-action) so a downstream failure
    leaves the mail refetchable instead of silently skipped."""
    if not os.path.exists(OUT_MAILS):
        sys.exit(f"{OUT_MAILS} not found — run the fetch first")
    with open(OUT_MAILS) as f:
        mails = json.load(f)
    save_cursor(m["message_id"] for m in mails)
    print(f"Cursor committed: {len(mails)} message ids -> {CURSOR_FILE}")


# ---- MAIN ------------------------------------------------------------------

def main():
    if not USER:
        sys.exit("Set IMAP_USER=you@example.com (your Proton Bridge account address)")
    if not PASS:
        sys.exit("Set BRIDGE_PASS=... (Proton Bridge app password — not your Proton account password)")

    cursor = load_cursor()
    since = cursor["last_date"] or SINCE
    already_seen = set(cursor["message_ids"])

    M = imaplib.IMAP4(HOST, PORT)
    M.starttls()
    M.login(USER, PASS)
    M.select(f'"{MAILBOX}"', readonly=True)

    raw_hits = []
    seen_mids = set()
    for token in SENDER_TOKENS:
        typ, data = M.search(None, "SINCE", since, "FROM", token)
        if typ != "OK":
            continue
        for i in data[0].split():
            typ, raw = M.fetch(i, "(RFC822)")
            if typ != "OK":
                continue
            rfc822 = next((item[1] for item in raw
                           if isinstance(item, tuple) and len(item) == 2), None)
            if not rfc822:
                continue
            msg = email.message_from_bytes(rfc822)
            mid = msg.get("Message-ID") or f"{MAILBOX}-{i.decode()}"
            if mid in seen_mids or mid in already_seen:
                continue
            seen_mids.add(mid)
            body, atts = extract_body(msg)
            raw_hits.append({
                "message_id": mid,
                "from": decode(msg.get("From")),
                "subject": decode(msg.get("Subject")),
                "date": msg.get("Date"),
                "in_reply_to": msg.get("In-Reply-To"),
                "references": msg.get("References"),
                "body_full": body,
                "body_new": strip_quoted(body),
                "_attachments": atts,
            })
    M.logout()

    if not raw_hits:
        print(f"No new mail since {since}. Nothing to do.")
        return

    os.makedirs(OUT_ATTACH_DIR, exist_ok=True)
    raw_hits.sort(key=lambda x: x.get("date") or "")

    # persist attachments + manifest
    manifest = {}
    for m in raw_hits:
        tk = thread_key(m["subject"], m["from"])
        m["thread_key"] = tk
        manifest.setdefault(tk, [])
        for a in m.pop("_attachments"):
            h = hashlib.sha1(a["payload"]).hexdigest()[:10]
            ext = os.path.splitext(a["filename"])[1] or ".png"
            unique = f"{tk}-{h}{ext}"
            path = os.path.join(OUT_ATTACH_DIR, unique)
            if not os.path.exists(path):
                with open(path, "wb") as f:
                    f.write(a["payload"])
            if not any(e["hash"] == h for e in manifest[tk]):
                manifest[tk].append({"filename": unique, "hash": h,
                                     "date": m["date"], "message_id": m["message_id"]})

    with open(OUT_MAILS, "w") as f:
        json.dump(raw_hits, f, ensure_ascii=False, indent=2)
    with open(OUT_MANIFEST, "w") as f:
        json.dump(manifest, f, ensure_ascii=False, indent=2)

    # summary
    threads = {}
    for m in raw_hits:
        threads.setdefault(m["thread_key"], []).append(m)
    print(f"Fetched {len(raw_hits)} messages in {len(threads)} threads.")
    for tk, items in sorted(threads.items()):
        print(f"  {tk}: {len(items)} msg | {len(manifest.get(tk, []))} attachments "
              f"| {items[0]['subject'][:60]}")
    print("Cursor NOT updated — run with --commit-cursor after these are handled.")


if __name__ == "__main__":
    commit_cursor() if "--commit-cursor" in sys.argv[1:] else main()
