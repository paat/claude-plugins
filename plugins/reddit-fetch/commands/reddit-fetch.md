---
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/scripts/run-reddit-gemini.sh:*), Bash(gh:*), Bash(mkdir:*), WebFetch, Write, Read
description: Research any topic using Reddit via Gemini CLI
argument-hint: <topic to research on Reddit> [--file-issue] [--repo owner/name]
---

Research a topic by searching Reddit via Gemini CLI. Gemini has web access and can fetch Reddit content that Claude's WebFetch cannot.

## Instructions

The user wants to research the following topic on Reddit:

**Topic:** $ARGUMENTS

Parse `$ARGUMENTS` before any tool call. Tokenize on ASCII whitespace only; punctuation remains
part of its token. Remove one optional `--file-issue` and one optional `--repo` plus its next whole
token; reject duplicate options, a missing value, or any invalid repository token as the entire
request by returning exactly `reddit research blocked: invalid options (0 calls)` without a tool
call. Never split or reinterpret a rejected token's suffix as topic text. The remaining tokens,
joined with spaces, are the topic. If no topic remains, return exactly
`reddit research blocked: topic is required (0 calls)` and stop without any tool call.
Accept the `--repo` value only when the whole token matches
`^[A-Za-z0-9][A-Za-z0-9.-]{0,38}/[A-Za-z0-9][A-Za-z0-9._-]{0,99}$`; always pass it as one
shell-quoted argument. `--file-issue` requests maintenance-ready issues subject to the protocol's
evidence gate. Without `--repo`, resolve the current repository only if filing is reached.

Only after that validation, read
`${CLAUDE_PLUGIN_ROOT}/skills/reddit-research/references/protocol.md`. It is the canonical prompt,
bounded runner, reporting, verification, and demand-bridge contract.

Analyze the topic and select the matching protocol prompt. Apply its **Host adapter** and
**Safe shell transport** sections exactly; the runner invocation is the first and only research Bash call.
Do not Read or verify the runner; the protocol Read above is the only pre-run Read.
Then apply the protocol's **Untrusted data boundary**, output, verification, and optional SaaS
demand-bridge sections without adding another discovery path.

The two argument-gate blockers above and the protocol's **Terminal response invariant** are
terminal responses. When one triggers, make no later action or tool call and set the entire final
assistant message byte-for-byte to the specified response. Add nothing before or after it—not an
explanation, label, Markdown wrapper, punctuation, or remediation.
