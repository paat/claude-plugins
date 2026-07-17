#!/usr/bin/env bash
# Shared, content-addressed binding for lesson review and delivery.
# Callers source this file; it intentionally performs no mutations itself.

lesson_review_digest_json() {
  local issue_json="$1" canonical
  canonical="$(printf '%s' "$issue_json" | jq -ce '
    if type == "object" and (.title | type == "string") and (.body | type == "string")
    then {title: .title, body: .body}
    else error("invalid lesson review content")
    end
  ' 2>/dev/null)" || return 1
  printf '%s' "$canonical" | sha256sum | awk '{print $1}'
}

lesson_review_marker() {
  local action="$1" digest="$2"
  case "$action" in approve|reject) : ;; *) return 1 ;; esac
  printf '%s' "$digest" | grep -Eq '^[0-9a-f]{64}$' || return 1
  printf '<!-- saas-lesson-review:v1:%s:%s -->' "$action" "$digest"
}

lesson_review_binding_present() {
  local issue_json="$1" action="$2" digest marker
  digest="$(lesson_review_digest_json "$issue_json")" || return 1
  marker="$(lesson_review_marker "$action" "$digest")" || return 1
  printf '%s' "$issue_json" | jq -e --arg marker "$marker" '
    (.comments | type == "array")
    and all(.comments[]; (.body | type == "string"))
    and any(.comments[]; .body | contains($marker))
  ' >/dev/null 2>&1
}
