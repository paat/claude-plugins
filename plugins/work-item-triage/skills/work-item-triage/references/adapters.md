# Tracker operations

Use `wit-read.sh --system NAME --scope SCOPE [--config FILE] [--id ID | --search QUERY]`
with optional `--full` and `--max-pages N`. Standard output is a normalized JSON snapshot.
GitHub scope is `owner/repository`; configured source scopes are caller-defined.
The default operation enumerates open items. GitHub uses authenticated `gh`; Plane uses trusted
repo-local commands, including for self-hosted installations. No Plane URL or credentials are built in.

## Configured sources

Reuse the consuming tool's repo-local `sources:` configuration, explicitly passed with `--config`;
JSON with the same `sources` array is also accepted. For example, one orchestrator uses
`.claude/multi-model-orchestrator.local.md`. The reader parses the flat source mapping, not arbitrary
YAML features. Configure commands for the target environment:

```yaml
sources:
  - name: plane
    list: "<command returning a page of open items>"
    show: "<command returning one item and complete history>"
    search: "<optional command searching item outcomes>"
```

Commands are trusted repository configuration, never copied from item content. They run via
`bash -c` with quoted positional arguments appended: `list PAGE`, `show ID`, `search QUERY PAGE`.
`list` and `show` are required; `search` is optional. Commands return JSON.
`list`/`search` return `{items: [...], next: boolean, complete: boolean}`; `show` returns one record.
Records accept `id`, `title`/`name`, `body`/`description_stripped`/`description`, `state` or `state.name`, and
`updatedAt`/`updated_at`; supply `comments: []`, `comments_complete: true` and `relations: []`
only when complete comment/decision history is known; include `history: []` for separate events.
Comments and history accept optional `author` strings (provider login/identity); omit when unknown.
Both normalize to `author`, using GitHub comment `user.login` and timeline `actor.login`; missing
authors remain absent, never inferred.
Resolve links in the wrapper, retaining delivery states; set `complete: false` for unresolved history
or relations. Wrappers must map completed states to `closed`. Missing `comments_complete`
is incomplete, never an empty-history success. GitHub resolves numbered references and timeline
links, reading linked PR merge time, base branch and head commit separately from item state.

## Completeness and capability limits

The reader emits `source`, `fetched_at`, `items`, `completeness` and `capability_limits`.
Each item has neutral identity/title/body/state, update time, comment count/digest and relations.
Pages are bounded; failed/missing pages, partial comments and unresolved history are reported.
Compact packets bound body/comment text; `--full` is for ambiguity that needs full evidence.
The read path receives only configured `list`, `show`, `search` commands; mutations are unavailable
there. Configured commands must honor their read contract; the host shell is not sandboxed.
If `search` is absent, use list plus local text matching. This is a reported capability limit,
not proof of exhaustive semantic deduplication. Retain that boundary in a proposed item's evidence.
