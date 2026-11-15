#!/usr/bin/env bash
# proton-bridge reply-draft tests: offline only. Every case builds the draft from a local
# parent (--parent-eml) into a file (--dry-run); nothing touches a network. The IMAP paths
# (--parent-uid, --parent-message-id, --from-draft-uid, the read-back) need a real server.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
RD="$(cd "$HERE/.." && pwd)/scripts/reply-draft.py"
PASS=0; FAIL=0
t() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then PASS=$((PASS+1)); echo "ok - $name"; else FAIL=$((FAIL+1)); echo "FAIL - $name"; fi; }

WD="$(mktemp -d)"
trap 'rm -rf "$WD"' EXIT
export MAIL_USER=me@example.org
OUT="$WD/out.eml"

# parent <file> <subject>: a multipart mail with a script, and a style in head and body
parent() {
  cat > "$1" <<EML
From: Sender Example <sender@example.com>
To: me@example.org, Other Person <other@example.com>, alias@example.org
Cc: boss@example.com
Subject: $2
Date: Sat, 14 Nov 2026 21:46:57 +0000
Message-ID: <parent-1@example.com>
References: <root-0@example.org>
MIME-Version: 1.0
Content-Type: multipart/alternative; boundary="BOUNDARY"

--BOUNDARY
Content-Type: text/plain; charset="utf-8"

Hello

What do you recommend?

--BOUNDARY
Content-Type: text/html; charset="utf-8"

<html><head><style>p{color:red}</style></head><body><style>b{color:blue}</style><p>Hello</p><p>What do you <b>recommend</b>?</p><script>alert(1)</script></body></html>

--BOUNDARY--
EML
}
parent "$WD/parent.eml" "=?utf-8?q?K=C3=BCsimus?= about the server"
printf 'Hi,\n\nI recommend option A.\nSecond line.\n\nRegards\n' > "$WD/body.txt"
printf '<html><body><p>Option <b>A</b> &amp; nothing else.</p></body></html>\n' > "$WD/body.html"
printf '   \n\n' > "$WD/empty.txt"
printf 'From: sender@example.com\nTo: me@example.org\nSubject: Empty\nMessage-ID: <e@example.com>\nContent-Type: text/plain\n\n\n' > "$WD/empty-parent.eml"
printf 'From: sender@example.com\nTo: me@example.org\nSubject: File\nMessage-ID: <f@example.com>\nContent-Type: application/octet-stream\nContent-Transfer-Encoding: base64\n\nAAEC\n' > "$WD/binary-parent.eml"

# draft [parent] [body] [options...] -> $OUT ; show <header|html|plain> prints that piece of $OUT
draft() { rm -f "$OUT"; python3 "$RD" --parent-eml "${1:-$WD/parent.eml}" --body-file "${2:-$WD/body.txt}" --dry-run "$OUT" "${@:3}"; }
show() {
  python3 - "$OUT" "$1" <<'PY'
import email, email.policy, sys
m = email.message_from_bytes(open(sys.argv[1], 'rb').read(), policy=email.policy.default)
k = sys.argv[2]
print(m.get_body(preferencelist=(k,)).get_content() if k in ('html', 'plain') else str(m.get(k, '')))
PY
}
has() { show "$1" | grep -qF -- "$2"; }
hasnt() { ! show "$1" | grep -qiF -- "$2"; }
is() { [ "$(show "$1")" = "$2" ]; }

draft "" "" >/dev/null 2>&1
t "To is the parent's sender" is To "Sender Example <sender@example.com>"
t "reply-all Cc keeps the other recipients" is Cc "Other Person <other@example.com>, alias@example.org, boss@example.com"
t "reply-all Cc excludes the user's own address" hasnt Cc "me@example.org"
t "From is the user" is From "me@example.org"
t "Re: is added, subject decoded" is Subject "Re: Küsimus about the server"
t "In-Reply-To is the parent's Message-ID" is In-Reply-To "<parent-1@example.com>"
t "References is the parent's chain plus the parent" is References "<root-0@example.org> <parent-1@example.com>"
t "html has the quote block" has html '<blockquote class="protonmail_quote" type="cite">'
t "html quote has the parent text" has html '<p>What do you <b>recommend</b>?</p>'
t "html has the attribution" has html 'Sender Example &lt;sender@example.com&gt; wrote:'
t "html has no parent script" hasnt html '<script'
t "html has no parent script body" hasnt html 'alert(1)'
t "html has no parent style tag" hasnt html '<style'
t "html has no parent head style" hasnt html 'color:red'
t "html has no parent body style" hasnt html 'color:blue'
t "plain body becomes paragraphs" has html '<p>Hi,</p><p>I recommend option A.<br>Second line.</p><p>Regards</p><br><div class="protonmail_quote">'
t "plain part starts with the body" has plain 'I recommend option A.'
plain_quote() { show plain | grep -qx '> Hello' && show plain | grep -qx '> What do you recommend?'; }
t "plain part quotes with '> '" plain_quote

json_flags() { draft "" "" | grep -q '"sent": false' && draft "" "" | grep -q '"stored": false'; }
t "output says nothing was sent or stored" json_flags

draft "" "" --me alias@example.org >/dev/null 2>&1
t "--me keeps another own address out of Cc" is Cc "Other Person <other@example.com>, boss@example.com"

draft "" "" --no-reply-all >/dev/null 2>&1
t "--no-reply-all gives no Cc" is Cc ""
t "--no-reply-all keeps To" is To "Sender Example <sender@example.com>"

draft "" "" --lang et >/dev/null 2>&1
t "--lang et attribution" has plain 'kirjutas Sender Example <sender@example.com>:'

for prefix in "Re:" "RE:" "Vs:"; do
  parent "$WD/re.eml" "$prefix About the server"
  draft "$WD/re.eml" "" >/dev/null 2>&1
  t "$prefix is not doubled" is Subject "$prefix About the server"
done

draft "" "$WD/body.html" >/dev/null 2>&1
t ".html body is used as HTML" has html '<p>Option <b>A</b> &amp; nothing else.</p><br><div class="protonmail_quote">'
t ".html body gives a plain part too" has plain 'Option A & nothing else.'

rc() { local want="$1"; shift; "$@" >/dev/null 2>&1; [ $? -eq "$want" ]; }
no_out() { [ ! -e "$OUT" ]; }
t "no body exits 2" rc 2 python3 "$RD" --parent-eml "$WD/parent.eml" --dry-run "$OUT"
t "no parent exits 2" rc 2 python3 "$RD" --body-file "$WD/body.txt" --dry-run "$OUT"
t "two bodies exit 2" rc 2 draft "" "" --from-draft-uid 5
t "two parents exit 2" rc 2 draft "" "" --parent-uid 5
t "missing connection settings exit 1 before any network" rc 1 python3 "$RD" --env-prefix RD_TEST_UNSET --parent-uid 5 --body-file "$WD/body.txt"
t "empty reply body exits 1" rc 1 draft "" "$WD/empty.txt"
t "empty reply body writes no draft" no_out
t "parent with an empty text exits 1" rc 1 draft "$WD/empty-parent.eml" ""
t "parent with an empty text writes no draft" no_out
t "parent with only a binary part exits 1" rc 1 draft "$WD/binary-parent.eml" ""
t "parent with only a binary part writes no draft" no_out

# --- cases from the independent review of the first version ---
mk() { printf '%b' "$2" > "$1"; }
HDR='To: me@example.org\nSubject: S\nMessage-ID: <p2@example.com>\nMIME-Version: 1.0\n'
mk "$WD/ws-plain.eml" "From: sender@example.com\nDate: Sat, 14 Nov 2026 21:46:57 +0000\n${HDR}Content-Type: multipart/alternative; boundary=\"B\"\n\n--B\nContent-Type: text/plain; charset=\"utf-8\"\n\n \n\n--B\nContent-Type: text/html; charset=\"utf-8\"\n\n<p>Real text here</p>\n--B--\n"
mk "$WD/no-from.eml" "Date: Sat, 14 Nov 2026 21:46:57 +0000\n${HDR}Content-Type: text/plain; charset=\"utf-8\"\n\nOrphan text\n"
mk "$WD/html-only.eml" "From: sender@example.com\nDate: Sat, 14 Nov 2026 21:46:57 +0000\n${HDR}Content-Type: text/html; charset=\"utf-8\"\n\n<html><head><title>TITLESECRET</title></head><body><p>Visible line</p></body></html>\n"
mk "$WD/plain-only.eml" "From: Sender Example <sender@example.com>\n${HDR}Content-Type: text/plain; charset=\"utf-8\"\n\nPlain parent line\n"
mk "$WD/bom.txt" '\xef\xbb\xbfBody after a BOM.\n'

draft "$WD/ws-plain.eml" "" >/dev/null 2>&1
t "whitespace-only plain part falls back to the HTML text" has plain '> Real text here'
t "parent without From and Reply-To exits 1" rc 1 draft "$WD/no-from.eml" ""
t "parent without From and Reply-To writes no draft" no_out
draft "$WD/html-only.eml" "" >/dev/null 2>&1
t "html-only parent is quoted in the plain part" has plain '> Visible line'
t "the parent's <title> stays out of the plain quote" hasnt plain 'TITLESECRET'
draft "$WD/plain-only.eml" "" >/dev/null 2>&1
t "plain-only parent is quoted in the HTML part" has html '<blockquote class="protonmail_quote" type="cite"><p>Plain parent line</p>'
t "a parent without Date gets a line without a date" has html 'Sender Example &lt;sender@example.com&gt; wrote:'
t "a parent without Date leaves no empty date" hasnt html 'On  at'
draft "" "$WD/bom.txt" >/dev/null 2>&1
nobom() { ! show plain | head -c 3 | grep -q "$(printf '\xef\xbb\xbf')"; }
t "a UTF-8 BOM in the body file is dropped" nobom

fd() { rm -f "$OUT"; python3 "$RD" --parent-eml "$WD/parent.eml" --from-draft-eml "$1" --dry-run "$OUT" "${@:2}"; }
count() { [ "$(show "$1" | grep -oF -- "$2" | wc -l)" -eq "$3" ]; }
DH='From: me@example.org\nSubject: Re: edited subject\nMIME-Version: 1.0\n'
mk "$WD/d-html.eml" "To: new@example.com\n${DH}Content-Type: text/html; charset=\"utf-8\"\n\n<p>My edited text</p><div class=\"protonmail_quote\">x wrote:<blockquote class=\"protonmail_quote\" type=\"cite\">OLDQUOTE</blockquote></div>\n"
mk "$WD/d-plain.eml" "To: new@example.com\n${DH}Content-Type: text/plain; charset=\"utf-8\"\n\nMy plain text\n\nOn some day x wrote:\n\n> OLDLINE one\n> OLDLINE two\n"
mk "$WD/d-norcpt.eml" "${DH}Content-Type: text/plain; charset=\"utf-8\"\n\nBody without recipients\n"
mk "$WD/d-cconly.eml" "Cc: boss@example.com\n${DH}Content-Type: text/plain; charset=\"utf-8\"\n\nBody with Cc only\n"

fd "$WD/d-html.eml" >/dev/null 2>&1
t "re-made draft keeps the user's text" has html '<p>My edited text</p>'
t "re-made draft drops the old quote" hasnt html 'OLDQUOTE'
t "re-made draft quotes the parent once" count html '<blockquote' 1
t "re-made draft keeps the draft's To" is To "new@example.com"
t "re-made draft does not bring back removed Cc" is Cc ""
t "re-made draft keeps the draft's subject" is Subject "Re: edited subject"
fd "$WD/d-plain.eml" >/dev/null 2>&1
t "plain draft: the user's text is kept" has plain 'My plain text'
t "plain draft: the old quote is dropped" hasnt plain 'OLDLINE'
t "plain draft: the old '... wrote:' line is dropped" hasnt plain 'On some day x wrote:'
fd "$WD/d-norcpt.eml" >/dev/null 2>&1
t "draft without recipients gets the parent's reply recipients" is To "Sender Example <sender@example.com>"
t "draft with Cc but no To exits 1" rc 1 fd "$WD/d-cconly.eml"
t "draft with Cc but no To writes no draft" no_out
t "three body sources exit 2" rc 2 fd "$WD/d-html.eml" --body-file "$WD/body.txt"

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
