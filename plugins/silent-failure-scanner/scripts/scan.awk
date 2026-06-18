# silent-failure-scanner: deterministic diff-time detector for swallowed errors.
#
# Reads a unified diff on stdin and reports the "agentic slop" silent-failure
# signature:
#   swallowed-exception   empty catch {} / except: pass — whether re-added OR emptied
#                         by deleting the body of an existing handler
#   unawaited-promise     an `await`/`yield` was removed from an otherwise-identical line
#   dropped-error-response a non-2xx/error response path was removed with no replacement
#   narrative-replacement a prose comment was added where real logic was removed
#
# Invoked by scan.sh. Variables:
#   FORMAT = "text" (default) | "json"
#   VERSION = plugin version string (for the json report)
#
# Per hunk we keep three views, all built in the body loop:
#   A[]/AL[]  added lines + their new-file line numbers   (unawaited, narrative, replacements)
#   R[]       removed lines                                (unawaited pairing, dropped response)
#   NF_*[]    the reconstructed NEW-file view (context + added, in order), with the count of
#             removed code lines that preceded each line  (empty-catch / emptied-handler)
#
# Portable awk (no gawk extensions, no \b, no IGNORECASE, no hex escapes).

function trim(s) { gsub(/^[ \t]+/, "", s); gsub(/[ \t]+$/, "", s); return s }

function detect_lang(path) {
  if (path ~ /\.(ts|tsx|mts|cts)$/) return "ts"
  if (path ~ /\.(js|jsx|mjs|cjs)$/) return "js"
  if (path ~ /\.py$/)               return "python"
  if (path ~ /\.cs$/)               return "csharp"
  if (path ~ /\.php$/)              return "php"
  return ""
}

function is_cstyle(lg) { return (lg == "ts" || lg == "js" || lg == "csharp" || lg == "php") }

# does the line carry an async marker as a standalone keyword (await foo / await(foo))?
function has_async_marker(s) {
  return (s ~ /(^|[^A-Za-z0-9_])await([ \t]|\()/) || (s ~ /(^|[^A-Za-z0-9_])yield([ \t]|\()/)
}

# strip the first async marker (await/yield), space- or paren-form, then trim
function strip_async_marker(s) {
  if (s ~ /(^|[^A-Za-z0-9_])await([ \t]|\()/)      { sub(/await[ \t]+/, "", s); sub(/await[ \t]*\(/, "(", s) }
  else if (s ~ /(^|[^A-Za-z0-9_])yield([ \t]|\()/) { sub(/yield[ \t]+/, "", s); sub(/yield[ \t]*\(/, "(", s) }
  return trim(s)
}

function is_comment_line(s,   t) {
  t = trim(s)
  return (t ~ /^\/\// || t ~ /^#/ || t ~ /^\/\*/ || t ~ /^\*/ || t ~ /^--/)
}
function is_code_line(s) { return (trim(s) != "" && !is_comment_line(s)) }
function is_close_brace(s) { return (s ~ /^[ \t]*\}[ \t]*;?[ \t]*$/) }

# conservative prose markers that signal "logic explained away" rather than documented
function is_narrative(s,   t) {
  t = tolower(s)
  return (t ~ /simplif/ || t ~ /no longer/ || t ~ /for now/ || t ~ /assume/ \
       || t ~ /should be fine/ || t ~ /handled elsewhere/ || t ~ /not needed/ \
       || t ~ /don'?t need/ || t ~ /just store/ || t ~ /just call/ || t ~ /just return/ \
       || t ~ /skip the/ || t ~ /leftover/ || t ~ /we can just/)
}

# response context carrying a 4xx/5xx status code
function is_error_response(s,   t) {
  t = tolower(s)
  if (!(t ~ /status|writeheader|sendstatus|httpstatus|abort\(|reject|response|throw new|res\.send/)) return 0
  return has_4xx5xx(s)
}
function has_4xx5xx(s) { return (s ~ /(^|[^0-9])(4[0-9][0-9]|5[0-9][0-9])([^0-9]|$)/) }

# does an added line look like a replacement error response (numeric OR symbolic)?
function is_replacement_response(s,   t) {
  if (has_4xx5xx(s)) return 1
  t = tolower(s)
  return (t ~ /unauthorized|forbidden|badrequest|bad_request|notfound|not_found|conflict/ \
       || t ~ /internalservererror|internal_server_error|unprocessable|toomanyrequests|too_many_requests/ \
       || t ~ /throw new|throw \$|raise |abort\(|reject\(/)
}

function reset_hunk() {
  delete A; delete AL; delete R; delete NF_t; delete NF_ln; delete NF_added; delete NF_rem
  na = 0; nr = 0; nnf = 0; pending_rem = 0
}

function nf_push(t, ln, added) {
  NF_t[nnf] = t; NF_ln[nnf] = ln; NF_added[nnf] = added; NF_rem[nnf] = pending_rem
  pending_rem = 0; nnf++
}

function emit(f, l, code, sev, lg, snip,   key) {
  key = f SUBSEP l SUBSEP code
  if (key in seen) return
  seen[key] = 1
  nf++
  F_file[nf] = f; F_line[nf] = l; F_code[nf] = code
  F_sev[nf] = sev; F_lang[nf] = lg; F_snip[nf] = trim(snip)
  if (sev == "high")        sev_high++
  else if (sev == "medium") sev_med++
  else                      sev_low++
}

# count removed lines that are real code (not blank, not comment)
function removed_code_lines(   i, c) {
  c = 0
  for (i = 0; i < nr; i++) if (is_code_line(R[i])) c++
  return c
}

function flush_hunk(   i, k, j, line, ln, t, found, remsum, dropped, drop_snip, anchor, replaced) {
  if (lang == "") { reset_hunk(); return }

  # --- unawaited-promise: build the de-marked set from removed lines ---
  delete deaw
  for (i = 0; i < nr; i++) if (has_async_marker(R[i])) deaw[strip_async_marker(R[i])] = 1
  for (i = 0; i < na; i++) {
    t = trim(A[i])
    if (t != "" && !has_async_marker(A[i]) && (t in deaw))
      emit(file, AL[i], "unawaited-promise", "high", lang, A[i])
  }

  # --- swallowed-exception over the reconstructed new-file view ---
  for (k = 0; k < nnf; k++) {
    line = NF_t[k]; ln = NF_ln[k]
    if (is_cstyle(lang)) {
      if (line ~ /catch[ \t]*(\([^)]*\))?[ \t]*\{[ \t]*\}[ \t]*;?[ \t]*$/) {
        if (NF_added[k]) emit(file, ln, "swallowed-exception", "high", lang, line)
      } else if (line ~ /catch[ \t]*(\([^)]*\))?[ \t]*\{[ \t]*$/) {
        remsum = 0; found = -1
        for (j = k + 1; j < nnf; j++) {
          remsum += NF_rem[j]
          if (is_code_line(NF_t[j])) { found = j; break }
        }
        if (found >= 0 && is_close_brace(NF_t[found]) && (remsum > 0 || NF_added[k]))
          emit(file, ln, "swallowed-exception", "high", lang, line)
      }
    } else if (lang == "python") {
      if (line ~ /(^|[ \t])except([ \t]|:|\()/ && line ~ /:[ \t]*pass[ \t]*$/) {
        if (NF_added[k]) emit(file, ln, "swallowed-exception", "high", lang, line)
      } else if (line ~ /(^|[ \t])except([ \t]|:|\()/ && line ~ /:[ \t]*$/) {
        remsum = 0; found = -1
        for (j = k + 1; j < nnf; j++) {
          remsum += NF_rem[j]
          if (is_code_line(NF_t[j])) { found = j; break }
        }
        if (found >= 0 && NF_t[found] ~ /^[ \t]*pass[ \t]*$/ && (remsum > 0 || NF_added[k] || NF_added[found]))
          emit(file, ln, "swallowed-exception", "high", lang, line)
      }
    }
  }

  # --- narrative-replacement: prose comment added where code was removed ---
  if (removed_code_lines() > 0)
    for (i = 0; i < na; i++)
      if (is_comment_line(A[i]) && is_narrative(A[i]))
        emit(file, AL[i], "narrative-replacement", "low", lang, A[i])

  # --- dropped-error-response: removed a non-2xx path, nothing added replaces it ---
  dropped = 0; drop_snip = ""
  for (i = 0; i < nr; i++) if (is_error_response(R[i])) { dropped = 1; if (drop_snip == "") drop_snip = trim(R[i]) }
  replaced = 0
  for (i = 0; i < na; i++) if (is_replacement_response(A[i])) replaced = 1
  if (dropped && !replaced) {
    anchor = hunk_newstart
    for (k = 0; k < nnf; k++) if (NF_rem[k] > 0) { anchor = NF_ln[k]; break }
    emit(file, anchor, "dropped-error-response", "medium", lang, drop_snip)
  }

  reset_hunk()
}

function json_escape(s) {
  gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s)
  gsub(/\t/, "\\t", s);  gsub(/\r/, "", s)
  return s
}

BEGIN { reset_hunk(); nf = 0; lang = ""; file = ""; curln = 0; hunk_newstart = 0 }

/^diff --git/ { flush_hunk(); file = ""; lang = ""; next }
/^--- /       { next }
/^\+\+\+ / {
  path = $0; sub(/^\+\+\+ /, "", path); sub(/^b\//, "", path)
  if (path == "/dev/null") path = ""
  file = path; lang = detect_lang(file); next
}
/^@@ / {
  flush_hunk()
  if (match($0, /\+[0-9]+/)) hunk_newstart = substr($0, RSTART + 1, RLENGTH - 1) + 0
  else hunk_newstart = 0
  curln = hunk_newstart
  next
}
/^\\/ { next }   # "\ No newline at end of file" — not a content line
{
  c = substr($0, 1, 1)
  if (c == "+")      { A[na] = substr($0, 2); AL[na] = curln; na++; nf_push(substr($0, 2), curln, 1); curln++ }
  else if (c == "-") { R[nr] = substr($0, 2); nr++; if (is_code_line(substr($0, 2))) pending_rem++ }
  else               { nf_push(substr($0, 2), curln, 0); curln++ }   # context line
}

END {
  flush_hunk()
  if (FORMAT == "json") {
    printf "{\"version\":\"%s\",\"findings\":[", (VERSION == "" ? "0.0.0" : VERSION)
    for (i = 1; i <= nf; i++) {
      printf "%s{\"file\":\"%s\",\"line\":%d,\"code\":\"%s\",\"severity\":\"%s\",\"lang\":\"%s\",\"snippet\":\"%s\"}", \
        (i > 1 ? "," : ""), json_escape(F_file[i]), F_line[i], F_code[i], F_sev[i], F_lang[i], json_escape(F_snip[i])
    }
    printf "],\"summary\":{\"total\":%d,\"high\":%d,\"medium\":%d,\"low\":%d}}\n", \
      nf, sev_high + 0, sev_med + 0, sev_low + 0
  } else {
    for (i = 1; i <= nf; i++)
      printf "%s:%d  [%s] %s: %s\n", F_file[i], F_line[i], toupper(F_sev[i]), F_code[i], F_snip[i]
    if (nf == 0) print "No silent-failure signatures found in diff." > "/dev/stderr"
    else printf "\n%d finding(s): %d high, %d medium, %d low\n", nf, sev_high + 0, sev_med + 0, sev_low + 0 > "/dev/stderr"
  }
  exit (nf > 0 ? 1 : 0)
}
