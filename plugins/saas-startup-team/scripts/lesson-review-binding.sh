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

# A binding comment is trusted only when its author association is repository-
# privileged, or when SAAS_LESSON_REVIEW_TRUSTED_LOGINS explicitly lists the
# author login (comma-separated). Unprivileged issue authors cannot forge
# approval by editing content and posting a matching digest marker.
lesson_review_comment_trusted() {
  local comment_json="$1" login assoc trusted
  login="$(printf '%s' "$comment_json" | jq -r '.author.login // empty')" || return 1
  [ -n "$login" ] || return 1
  assoc="$(printf '%s' "$comment_json" | jq -r '.authorAssociation // empty')" || return 1
  case "$assoc" in
    OWNER|MEMBER|COLLABORATOR) return 0 ;;
  esac
  trusted="${SAAS_LESSON_REVIEW_TRUSTED_LOGINS:-}"
  [ -n "$trusted" ] || return 1
  printf '%s' "$trusted" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' \
    | grep -Fxq -- "$login"
}

lesson_review_binding_present() {
  local issue_json="$1" action="$2" digest marker comment
  digest="$(lesson_review_digest_json "$issue_json")" || return 1
  marker="$(lesson_review_marker "$action" "$digest")" || return 1
  printf '%s' "$issue_json" | jq -e --arg marker "$marker" '
    (.comments | type == "array")
    and all(.comments[];
      (.body | type == "string")
      and ((.author // {}) | type == "object")
      and ((.author.login // null) | type == "string")
      and ((.authorAssociation // "") | type == "string"))
  ' >/dev/null 2>&1 || return 1
  while IFS= read -r comment; do
    [ -n "$comment" ] || continue
    printf '%s' "$comment" | jq -e --arg marker "$marker" '
      .body | contains($marker)
    ' >/dev/null 2>&1 || continue
    lesson_review_comment_trusted "$comment" && return 0
  done < <(printf '%s' "$issue_json" | jq -c '.comments[]')
  return 1
}
