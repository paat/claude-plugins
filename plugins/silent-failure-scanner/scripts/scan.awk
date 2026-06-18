# silent-failure-scanner: deterministic diff-time detector for swallowed errors.
#
# Reads a unified diff on stdin and reports the "agentic slop" silent-failure
# signature on ADDED lines:
#   swallowed-exception   empty catch {} / except: pass / broadened+discarded handler
#   unawaited-promise     an `await`/`yield` was removed from an otherwise-identical line
#   dropped-error-response a non-2xx/error response path was removed with no replacement
#   narrative-replacement a prose comment was added where real logic was removed
#
# Invoked by scan.sh. Variables:
#   FORMAT = "text" (default) | "json"
#   VERSION = plugin version string (for the json report)
#
# Findings are buffered per hunk so two-line patterns and removed/added pairing work.
# Portable awk (no gawk extensions, no \b, no IGNORECASE).

function trim(s) { gsub(/^[ \t]+/, "", s); gsub(/[ \t]+$/, "", s); return s }

function detect_lang(path,   ext) {
  if (path ~ /\.(ts|tsx|mts|cts)$/) return "ts"
  if (path ~ /\.(js|jsx|mjs|cjs)$/) return "js"
  if (path ~ /\.py$/)               return "python"
  if (path ~ /\.cs$/)               return "csharp"
  if (path ~ /\.php$/)              return "php"
  return ""
}

function is_cstyle(lg) { return (lg == "ts" || lg == "js" || lg == "csharp" || lg == "php") }

# does the line carry an async marker as a standalone keyword?
function has_async_marker(s) {
  return (s ~ /(^|[^A-Za-z0-9_])await[ \t]/) || (s ~ /(^|[^A-Za-z0-9_])yield[ \t]/)
}

# strip the first async marker (await/yield) + following spaces, then trim
function strip_async_marker(s) {
  if (s ~ /(^|[^A-Za-z0-9_])await[ \t]/)      sub(/await[ \t]+/, "", s)
  else if (s ~ /(^|[^A-Za-z0-9_])yield[ \t]/) sub(/yield[ \t]+/, "", s)
  return trim(s)
}

function is_comment_line(s,   t) {
  t = trim(s)
  return (t ~ /^\/\// || t ~ /^#/ || t ~ /^\/\*/ || t ~ /^\*/ || t ~ /^--/)
}

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
  return (t ~ /(^|[^0-9])(4[0-9][0-9]|5[0-9][0-9])([^0-9]|$)/)
}
function has_4xx5xx(s) { return (s ~ /(^|[^0-9])(4[0-9][0-9]|5[0-9][0-9])([^0-9]|$)/) }

function reset_hunk() { delete A; delete AL; delete R; na = 0; nr = 0 }

function emit(f, l, code, sev, lg, snip,   key) {
  key = f SUBSEP l SUBSEP code
  if (key in seen) return
  seen[key] = 1
  nf++
  F_file[nf] = f; F_line[nf] = l; F_code[nf] = code
  F_sev[nf] = sev; F_lang[nf] = lg; F_snip[nf] = trim(snip)
  if (sev == "high")   sev_high++
  else if (sev == "medium") sev_med++
  else                 sev_low++
}

function flush_hunk(   i, line, ln, t, dropped_ctx, added_has_status, drop_line) {
  if (lang == "") { reset_hunk(); return }

  # --- build the de-awaited set from removed lines (for unawaited-promise) ---
  delete deaw
  for (i = 0; i < nr; i++) {
    if (has_async_marker(R[i])) deaw[strip_async_marker(R[i])] = 1
  }

  # --- dropped-error-response: removed a non-2xx path, nothing added replaces it ---
  dropped_ctx = 0; drop_line = hunk_newstart
  for (i = 0; i < nr; i++) if (is_error_response(R[i])) dropped_ctx = 1
  added_has_status = 0
  for (i = 0; i < na; i++) if (has_4xx5xx(A[i])) added_has_status = 1

  # --- per added-line detectors ---
  for (i = 0; i < na; i++) {
    line = A[i]; ln = AL[i]; t = trim(line)
    if (i == 0) drop_line = ln

    # swallowed-exception (C-style: ts/js/csharp/php)
    if (is_cstyle(lang)) {
      if (line ~ /catch[ \t]*(\([^)]*\))?[ \t]*\{[ \t]*\}[ \t]*;?[ \t]*$/) {
        emit(file, ln, "swallowed-exception", "high", lang, line)
      } else if (line ~ /catch[ \t]*(\([^)]*\))?[ \t]*\{[ \t]*$/) {
        if (i + 1 < na && AL[i+1] == ln + 1 && A[i+1] ~ /^[ \t]*\}[ \t]*;?[ \t]*$/)
          emit(file, ln, "swallowed-exception", "high", lang, line)
      }
    } else if (lang == "python") {
      if (line ~ /(^|[ \t])except([ \t]|:|\()/ && line ~ /:[ \t]*pass[ \t]*$/) {
        emit(file, ln, "swallowed-exception", "high", lang, line)
      } else if (line ~ /(^|[ \t])except([ \t]|:|\()/ && line ~ /:[ \t]*$/) {
        if (i + 1 < na && AL[i+1] == ln + 1 && A[i+1] ~ /^[ \t]*pass[ \t]*$/)
          emit(file, ln, "swallowed-exception", "high", lang, line)
      }
    }

    # unawaited-promise: identical line with the async marker removed
    if (t != "" && !has_async_marker(line) && (t in deaw))
      emit(file, ln, "unawaited-promise", "high", lang, line)

    # narrative-replacement: prose comment added where code was removed
    if (is_comment_line(line) && is_narrative(line) && removed_code_lines() > 0)
      emit(file, ln, "narrative-replacement", "low", lang, line)
  }

  if (dropped_ctx && !added_has_status)
    emit(file, drop_line, "dropped-error-response", "medium", lang, "removed non-2xx response path")

  reset_hunk()
}

# count removed lines that are real code (not blank, not comment)
function removed_code_lines(   i, c) {
  c = 0
  for (i = 0; i < nr; i++) if (trim(R[i]) != "" && !is_comment_line(R[i])) c++
  return c
}

function json_escape(s) {
  gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s)
  gsub(/\t/, "\\t", s);  gsub(/\r/, "", s)
  return s
}

BEGIN { na = 0; nr = 0; nf = 0; lang = ""; file = ""; curln = 0; hunk_newstart = 0 }

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
{
  c = substr($0, 1, 1)
  if (c == "+")      { A[na] = substr($0, 2); AL[na] = curln; na++; curln++ }
  else if (c == "-") { R[nr] = substr($0, 2); nr++ }
  else               { curln++ }   # context line (leading space) or blank
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
    if (nf == 0) print "\xe2\x9c\x93 No silent-failure signatures found in diff." > "/dev/stderr"
    else printf "\n%d finding(s): %d high, %d medium, %d low\n", nf, sev_high + 0, sev_med + 0, sev_low + 0 > "/dev/stderr"
  }
  exit (nf > 0 ? 1 : 0)
}
