#!/usr/bin/env python3
"""Create a REPLY DRAFT over IMAP: reply-all recipients, "Re:" subject and the parent mail quoted under the body.

It never sends. The draft lands in the Drafts mailbox for a human to read, edit and send.

    reply-draft.py --parent-uid 123 [--parent-box INBOX] --body-file body.html
    reply-draft.py --parent-message-id '<id@host>' --body-file body.txt
    reply-draft.py --parent-uid 123 --from-draft-uid 45       # re-make an existing (edited) draft WITH the quote
    reply-draft.py --parent-eml parent.eml --body-file body.txt --dry-run out.eml   # no IMAP at all

Connection comes from the environment (optionally loaded with --env-file KEY=VALUE lines), names built from
--env-prefix (default MAIL): <P>_IMAP_HOST, <P>_IMAP_PORT, <P>_USER, <P>_PASSWORD.
Prints one JSON object describing what was created. Exit code 0 only when the draft was read back with the quote in it.
"""
import argparse
import datetime
import email
import email.policy
import html
import imaplib
import json
import os
import re
import ssl
import sys
import time
from email.message import EmailMessage
from email.utils import formataddr, formatdate, getaddresses, make_msgid, parsedate_to_datetime

QUOTE_CLASS = 'protonmail_quote'   # Proton's own marker; other clients show it as an ordinary blockquote
ATTRIBUTION = {
    'en': 'On {date} at {time}, {who} wrote:',
    'et': '{date} kell {time} kirjutas {who}:',
}
RE_PREFIX = re.compile(r'^\s*(re|vs|aw|sv|antw)\s*:', re.I)


def load_env_file(path):
    for line in open(path, encoding='utf-8'):
        line = line.strip()
        if line and not line.startswith('#') and '=' in line:
            k, v = line.split('=', 1)
            k = k.replace('export ', '').strip()
            v = v.strip()
            if len(v) >= 2 and v[0] == v[-1] and v[0] in '"\'':
                v = v[1:-1]
            os.environ.setdefault(k, v)


def connect(a):
    p = a.env_prefix
    try:
        host, user, pw = os.environ[p + '_IMAP_HOST'], os.environ[p + '_USER'], os.environ[p + '_PASSWORD']
    except KeyError as e:
        sys.exit(f'missing environment variable {e.args[0]} (prefix {p}; see --env-file / --env-prefix)')
    port = int(os.environ.get(p + '_IMAP_PORT', '993' if a.tls == 'ssl' else '143'))
    ctx = ssl.create_default_context()
    if a.insecure:   # a local bridge with a self-signed certificate
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
    if a.tls == 'ssl':
        m = imaplib.IMAP4_SSL(host, port, ssl_context=ctx)
    else:
        m = imaplib.IMAP4(host, port)
        m.starttls(ctx)
    m.login(user, pw)
    return m, user


def q(box):
    return '"' + box.replace('"', '\\"') + '"'


def fetch_uid(m, box, uid):
    typ, _ = m.select(q(box), readonly=True)
    if typ != 'OK':
        sys.exit(f'cannot open mailbox {box}')
    typ, d = m.uid('fetch', str(uid), '(BODY.PEEK[])')
    if typ != 'OK' or not d or not isinstance(d[0], tuple):
        sys.exit(f'no message with UID {uid} in {box}')
    return email.message_from_bytes(d[0][1], policy=email.policy.default)


def find_by_message_id(m, box, mid):
    typ, _ = m.select(q(box), readonly=True)
    if typ != 'OK':
        sys.exit(f'cannot open mailbox {box}')
    typ, d = m.uid('search', None, 'HEADER', 'Message-ID', mid.strip('<>'))
    ids = d[0].split() if typ == 'OK' and d and d[0] else []
    if len(ids) != 1:
        sys.exit(f'{len(ids)} messages with Message-ID {mid} in {box}; pass --parent-uid instead')
    return fetch_uid(m, box, ids[0].decode())


def part_text(msg, subtype):
    part = msg.get_body(preferencelist=(subtype,))
    if part is None:
        return None
    try:
        return part.get_content()
    except (LookupError, UnicodeError):
        return part.get_payload(decode=True).decode('utf-8', 'replace')


def html_inner(doc):
    """The inside of <body>, without scripts, styles, head and document wrappers."""
    doc = re.sub(r'(?is)<(script|style)\b.*?</\1>', '', doc)
    mb = re.search(r'(?is)<body\b[^>]*>(.*)</body>', doc)
    if mb:
        return mb.group(1).strip()
    doc = re.sub(r'(?is)<head\b.*?</head>', '', doc)
    return re.sub(r'(?is)</?(html|body|!doctype)\b[^>]*>', '', doc).strip()


def text_to_html(text):
    paras = [p for p in re.split(r'\n\s*\n', text.strip()) if p.strip()]
    return ''.join('<p>' + html.escape(p).replace('\n', '<br>') + '</p>' for p in paras)


def html_to_text(h):
    h = re.sub(r'(?is)<(style|script)\b.*?</\1>', '', h)
    h = re.sub(r'(?i)<br\s*/?>|</(p|div|tr|li|h[1-6]|blockquote)>', '\n', h)
    h = re.sub(r'(?i)</t[dh]>', '\t', h)
    return re.sub(r'\n{3,}', '\n\n', html.unescape(re.sub(r'<[^>]+>', '', h))).strip()


def strip_quote(h):
    """Drop an existing quote block, so re-making a draft does not quote twice."""
    i = h.find(f'<div class="{QUOTE_CLASS}"')
    return h[:i].rstrip() if i >= 0 else h


def attribution(parent, lang):
    name, addr = getaddresses([str(parent.get('From', ''))])[0]
    who = f'{name} <{addr}>' if name else addr
    try:
        dt = parsedate_to_datetime(str(parent['Date'])).astimezone()
        date, tm = dt.strftime('%d.%m.%Y'), dt.strftime('%H:%M')
    except (TypeError, ValueError):
        date, tm = str(parent.get('Date', '')), ''
    return ATTRIBUTION[lang].format(date=date, time=tm, who=who)


def addrs(msg, *names):
    out = []
    for n in names:
        out += [(nm, ad) for nm, ad in getaddresses([str(v) for v in msg.get_all(n, [])]) if ad]
    return out


def reply_recipients(parent, mine, reply_all):
    to = addrs(parent, 'Reply-To') or addrs(parent, 'From')
    seen = {a.lower() for _, a in to} | {m.lower() for m in mine}
    cc = []
    if reply_all:
        for nm, ad in addrs(parent, 'To', 'Cc'):
            if ad.lower() not in seen:
                seen.add(ad.lower())
                cc.append((nm, ad))
    return to, cc


def build(parent, body_html, body_text, me, to, cc, subject, lang):
    att = attribution(parent, lang)
    p_html = part_text(parent, 'html')
    p_text = part_text(parent, 'plain')
    quoted_html = html_inner(p_html) if p_html else text_to_html(p_text or '')
    quoted_text = (p_text or html_to_text(p_html or '')).strip()
    full_html = (f'{body_html}<br><div class="{QUOTE_CLASS}">{html.escape(att)}<br>'
                 f'<blockquote class="{QUOTE_CLASS}" type="cite">{quoted_html}</blockquote><br></div>')
    full_text = body_text.rstrip() + '\n\n' + att + '\n\n' + '\n'.join('> ' + l for l in quoted_text.split('\n')) + '\n'
    m = EmailMessage()
    m['From'] = me
    m['To'] = ', '.join(formataddr(x) for x in to)
    if cc:
        m['Cc'] = ', '.join(formataddr(x) for x in cc)
    m['Subject'] = subject
    m['Date'] = formatdate(localtime=True)
    m['Message-ID'] = make_msgid(domain=me.rsplit('@', 1)[-1])
    pid = str(parent.get('Message-ID', '')).strip()
    if pid:   # kept for servers that store them; Proton Bridge drops both on a draft (see SKILL.md)
        m['In-Reply-To'] = pid
        m['References'] = ' '.join(x for x in (str(parent.get('References', '')).strip(), pid) if x)
    m.set_content(full_text)
    m.add_alternative(full_html, subtype='html')
    return m, len(quoted_text)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    g = ap.add_argument_group('parent (the mail being answered)')
    g.add_argument('--parent-uid')
    g.add_argument('--parent-message-id')
    g.add_argument('--parent-box', default='INBOX')
    g.add_argument('--parent-eml', help='read the parent from a local .eml file instead of IMAP')
    g = ap.add_argument_group('body of the reply')
    g.add_argument('--body-file', help='.html/.htm is used as HTML, anything else as plain text')
    g.add_argument('--from-draft-uid', help='take body, recipients and subject from this existing draft')
    g = ap.add_argument_group('options')
    g.add_argument('--no-reply-all', action='store_true')
    g.add_argument('--me', action='append', default=[], help='another address of yours to keep out of Cc (repeatable)')
    g.add_argument('--lang', choices=sorted(ATTRIBUTION), default='en', help='language of the "… wrote:" line')
    g.add_argument('--drafts-box', default='Drafts')
    g.add_argument('--env-file')
    g.add_argument('--env-prefix', default='MAIL')
    g.add_argument('--tls', choices=('starttls', 'ssl'), default='starttls')
    g.add_argument('--insecure', action='store_true', help='do not verify the server certificate (local bridge)')
    g.add_argument('--dry-run', metavar='OUT.eml', help='write the draft to a file; nothing is stored on the server')
    a = ap.parse_args()
    if bool(a.body_file) == bool(a.from_draft_uid):
        ap.error('give exactly one of --body-file and --from-draft-uid')
    if sum(map(bool, (a.parent_uid, a.parent_message_id, a.parent_eml))) != 1:
        ap.error('give exactly one of --parent-uid, --parent-message-id and --parent-eml')
    if a.env_file:
        load_env_file(a.env_file)

    offline = bool(a.parent_eml and a.dry_run and a.body_file)
    m, me = (None, os.environ.get(a.env_prefix + '_USER', 'me@example.invalid')) if offline else connect(a)

    if a.parent_eml:
        parent = email.message_from_bytes(open(a.parent_eml, 'rb').read(), policy=email.policy.default)
    elif a.parent_uid:
        parent = fetch_uid(m, a.parent_box, a.parent_uid)
    else:
        parent = find_by_message_id(m, a.parent_box, a.parent_message_id)

    to, cc = reply_recipients(parent, [me] + a.me, not a.no_reply_all)
    subject = str(parent.get('Subject', '')).strip()
    if not RE_PREFIX.match(subject):
        subject = 'Re: ' + subject

    if a.from_draft_uid:
        old = fetch_uid(m, a.drafts_box, a.from_draft_uid)
        oh, ot = part_text(old, 'html'), part_text(old, 'plain')
        body_html = strip_quote(html_inner(oh)) if oh else text_to_html(ot or '')
        body_text = html_to_text(body_html)
        to = addrs(old, 'To') or to          # the human may have changed them: the draft wins
        cc = addrs(old, 'Cc') if old.get('To') else cc
        subject = str(old.get('Subject', subject)).strip() or subject
    else:
        raw = open(a.body_file, encoding='utf-8').read()
        if a.body_file.lower().endswith(('.html', '.htm')):
            body_html, body_text = html_inner(raw), html_to_text(raw)
        else:
            body_html, body_text = text_to_html(raw), raw.strip()
    if not body_text.strip():
        sys.exit('the reply body is empty')

    msg, quoted_chars = build(parent, body_html, body_text, me, to, cc, subject, a.lang)
    out = {'subject': subject, 'to': [x[1] for x in to], 'cc': [x[1] for x in cc], 'quoted_chars': quoted_chars,
           'message_id': str(msg['Message-ID']), 'sent': False}
    if quoted_chars == 0:
        sys.exit('the parent mail has no readable text to quote')

    if a.dry_run:
        open(a.dry_run, 'wb').write(msg.as_bytes())
        out.update(stored=False, file=a.dry_run)
        print(json.dumps(out, ensure_ascii=False))
        return

    typ, resp = m.append(q(a.drafts_box), '(\\Draft \\Seen)', imaplib.Time2Internaldate(time.time()), msg.as_bytes())
    if typ != 'OK':
        sys.exit(f'APPEND to {a.drafts_box} failed: {resp}')
    mu = re.search(rb'APPENDUID \d+ (\d+)', resp[0] or b'')
    m.select(q(a.drafts_box), readonly=True)
    uid = mu.group(1).decode() if mu else None
    if not uid:   # server without UIDPLUS: newest message in Drafts
        typ, d = m.uid('search', None, 'ALL')
        uid = d[0].split()[-1].decode()
    back = fetch_uid(m, a.drafts_box, uid)
    bh = part_text(back, 'html') or ''
    out.update(stored=True, drafts_box=a.drafts_box, uid=uid,
               quote_in_stored_draft=QUOTE_CLASS in bh or '> ' in (part_text(back, 'plain') or ''),
               reply_headers_kept=bool(back.get('In-Reply-To')))
    if a.from_draft_uid:
        out['old_draft_uid_left_in_place'] = a.from_draft_uid
    m.logout()
    print(json.dumps(out, ensure_ascii=False))
    sys.exit(0 if out['quote_in_stored_draft'] else 1)


if __name__ == '__main__':
    main()
