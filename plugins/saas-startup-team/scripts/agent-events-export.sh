#!/usr/bin/env bash
# Produce a strictly allowlisted, project-anonymous evaluation export.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
EVENTS="" LEGACY_ROOT="" OUT=""

usage() {
  echo "usage: agent-events-export.sh --out FILE [--events FILE] [--legacy-root DIR]" >&2
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --events) [ "$#" -ge 2 ] || usage; EVENTS="$2"; shift 2 ;;
    --legacy-root) [ "$#" -ge 2 ] || usage; LEGACY_ROOT="$2"; shift 2 ;;
    --out) [ "$#" -ge 2 ] || usage; OUT="$2"; shift 2 ;;
    *) usage ;;
  esac
done
[ -n "$OUT" ] || usage

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
records="$tmpdir/records.jsonl"
latest="$tmpdir/latest.json"
candidate="$tmpdir/export.json"

read_args=()
[ -z "$EVENTS" ] || read_args+=(--events "$EVENTS")
[ -z "$LEGACY_ROOT" ] || read_args+=(--legacy-root "$LEGACY_ROOT")
if ! "$SCRIPT_DIR/agent-events.sh" read "${read_args[@]}" > "$records"; then
  echo "agent-events-export: event parsing failed" >&2
  exit 3
fi

jq -s '
  def rank: if .event_type == "completed" then 2 elif .event_type == "progress" then 1 else 0 end;
  sort_by(.run_id, .command, .phase, .attempt, rank)
  | group_by([.run_id,.command,.phase,.attempt])
  | map(last)
' "$records" > "$latest"

jq '
  def norm_provider:
    if . == null or . == "" then null
    else (ascii_downcase) as $v
    | if ["openai","anthropic","google","xai","local"] | index($v) then $v else "other" end
    end;
  def norm_model:
    if . == null or . == "" then null
    else (ascii_downcase) as $v
    | if $v == "gpt-5.6-sol" or $v == "gpt-5.6-terra" then $v
      elif $v == "fable" or ($v | test("^claude-fable(-[0-9]+)*$")) then "claude-fable"
      elif $v == "opus" or ($v | test("^claude-opus(-[0-9]+)*$")) then "claude-opus"
      elif $v == "sonnet" or ($v | test("^claude-sonnet(-[0-9]+)*$")) then "claude-sonnet"
      elif $v == "haiku" or ($v | test("^claude-haiku(-[0-9]+)*$")) then "claude-haiku"
      elif ($v | test("^gemini-[0-9]+([.-][a-z0-9]+)*$")) then "gemini"
      elif ($v | test("^grok-[0-9]+([.-][a-z0-9]+)*$")) then "grok"
      else "other"
      end
    end;
  def norm_effort:
    if . == null or . == "" then null
    else (ascii_downcase) as $v
    | if ["low","medium","high","xhigh","max"] | index($v) then $v else "other" end
    end;
  def norm_profile:
    if . == null or . == "" then null
    else (ascii_downcase) as $v
    | if ["mechanical","light","standard","deep"] | index($v) then $v else "other" end
    end;
  def norm_status:
    if . == null or . == "" then null
    else (ascii_downcase) as $v
    | if ["not_run","not_started","not_created","not_applicable","not_needed","pending","passed","failed","blocked","skipped","incomplete","draft","open","closed","merged","rolled_back","cancelled","success"] | index($v)
      then $v else "other" end
    end;
  def norm_outcome:
    if . == null or . == "" then null
    else (ascii_downcase) as $v
    | if ["incomplete","success","failure","blocked","skipped","no-op","escalated","cancelled"] | index($v)
      then $v else "other" end
    end;
  def count_by(f):
    [ .[] | f | select(. != null and . != "") ]
    | group_by(.) | map({key:.[0],value:length}) | from_entries;
  def values(f): [ .[] | f | select(type == "number") ] | sort;
  def total($o): [$o[]] | add // 0;
  def rate($n;$d): if $d == 0 then null else (($n * 1000000 / $d | floor) / 1000000) end;
  . as $rows
  | ($rows | length) as $samples
  | ([$rows[].run_id] | unique | length) as $runs
  | ($rows | count_by(.outcome | norm_outcome)) as $outcomes
  | ($rows | count_by(.checks | norm_status)) as $checks
  | ($rows | count_by(.qa | norm_status)) as $qa
  | ($rows | count_by(.tribunal | norm_status)) as $tribunal
  | ($rows | count_by(.pr | norm_status)) as $pr
  | ($rows | count_by(.merge | norm_status)) as $merge
  | ($rows | count_by(.deployment | norm_status)) as $deployment
  | ($rows | count_by(.rollback | norm_status)) as $rollback
  | {
      schema_version:1,
      kind:"delivery-evaluation-export",
      sample_count:$samples,
      run_count:$runs,
      metrics:{
        profiles:($rows | count_by(.profile | norm_profile)),
        routing_schema_versions:($rows | count_by(.routing_schema_version | tostring)),
        outcomes:$outcomes,
        providers:{requested:($rows | count_by(.requested_provider | norm_provider)),effective:($rows | count_by(.effective_provider | norm_provider))},
        models:{requested:($rows | count_by(.requested_model | norm_model)),effective:($rows | count_by(.effective_model | norm_model))},
        efforts:{requested:($rows | count_by(.requested_effort | norm_effort)),effective:($rows | count_by(.effective_effort | norm_effort))},
        phase_statuses:{checks:$checks,qa:$qa,tribunal:$tribunal,pr:$pr,merge:$merge,deployment:$deployment,rollback:$rollback},
        fallback_count:([$rows[] | select((.routing_reasons // []) | index("terra_unavailable_fallback"))] | length),
        duration_ms:($rows | values(.duration_ms)),
        tokens_available_before:($rows | values(.tokens_available_before)),
        tokens_available_after:($rows | values(.tokens_available_after)),
        input_tokens:($rows | values(.input_tokens)),
        output_tokens:($rows | values(.output_tokens)),
        cached_input_tokens:($rows | values(.cached_input_tokens)),
        cost_microunits:($rows | values(.cost_microunits))
      },
      rates:{
        success:{numerator:($outcomes.success // 0),denominator:$samples,value:rate(($outcomes.success // 0);$samples)},
        checks_passed:{numerator:($checks.passed // 0),denominator:total($checks),value:rate(($checks.passed // 0);total($checks))},
        qa_passed:{numerator:($qa.passed // 0),denominator:total($qa),value:rate(($qa.passed // 0);total($qa))},
        tribunal_passed:{numerator:($tribunal.passed // 0),denominator:total($tribunal),value:rate(($tribunal.passed // 0);total($tribunal))},
        merged:{numerator:($merge.merged // 0),denominator:total($merge),value:rate(($merge.merged // 0);total($merge))},
        deployed:{numerator:($deployment.passed // 0),denominator:total($deployment),value:rate(($deployment.passed // 0);total($deployment))}
      }
    }
' "$latest" > "$candidate"

# The export is constructed from an allowlist, never copied from raw event objects.
if ! jq -e '
  def uint: type == "number" and . >= 0 and floor == .;
  def exact_keys($allowed): type == "object" and ((keys | sort) == ($allowed | sort));
  def countmap: type == "object" and all(.[]; uint);
  def routing_versions:
    type == "object" and (to_entries | all(.[]; (.key | test("^[0-9]+$")) and (.value | uint)));
  def count_total: if type == "object" then ([.[]] | add // 0) else -1 end;
  def uint_values: type == "array" and all(.[]; uint);
  def expected_rate($n;$d): (($n * 1000000 / $d | floor) / 1000000);
  def rate_object($n;$d):
    exact_keys(["denominator","numerator","value"])
    and (.numerator | uint) and (.denominator | uint)
    and .numerator == $n and .denominator == $d and .numerator <= .denominator
    and (if $d == 0 then .value == null
         else (.value | type == "number" and . >= 0 and . <= 1)
           and .value == expected_rate($n;$d)
         end);
  . as $export
  | exact_keys(["kind","metrics","rates","run_count","sample_count","schema_version"])
  and .schema_version == 1 and .kind == "delivery-evaluation-export"
  and (.sample_count | uint) and (.run_count | uint) and .run_count <= .sample_count
  and (.metrics | exact_keys([
    "cached_input_tokens","cost_microunits","duration_ms","efforts","fallback_count","input_tokens","models","outcomes",
    "output_tokens","phase_statuses","profiles","providers","routing_schema_versions","tokens_available_after","tokens_available_before"
  ]))
  and (.metrics.providers | exact_keys(["effective","requested"]))
  and (.metrics.models | exact_keys(["effective","requested"]))
  and (.metrics.efforts | exact_keys(["effective","requested"]))
  and (.metrics.phase_statuses | exact_keys(["checks","deployment","merge","pr","qa","rollback","tribunal"]))
  and (.metrics.profiles | countmap) and (.metrics.outcomes | countmap)
  and (.metrics.routing_schema_versions | routing_versions)
  and ([.metrics.providers[],.metrics.models[],.metrics.efforts[],.metrics.phase_statuses[]] | all(countmap))
  and (.metrics.fallback_count | uint) and .metrics.fallback_count <= .sample_count
  and ([.metrics.duration_ms,.metrics.tokens_available_before,.metrics.tokens_available_after,.metrics.input_tokens,
        .metrics.output_tokens,.metrics.cached_input_tokens,.metrics.cost_microunits] | all(uint_values))
  and (.metrics.outcomes | count_total) == .sample_count
  and (.metrics.routing_schema_versions | count_total) == .sample_count
  and (.rates | exact_keys(["checks_passed","deployed","merged","qa_passed","success","tribunal_passed"]))
  and (.rates.success | rate_object(($export.metrics.outcomes.success // 0);$export.sample_count))
  and (.rates.checks_passed | rate_object(($export.metrics.phase_statuses.checks.passed // 0);($export.metrics.phase_statuses.checks | count_total)))
  and (.rates.qa_passed | rate_object(($export.metrics.phase_statuses.qa.passed // 0);($export.metrics.phase_statuses.qa | count_total)))
  and (.rates.tribunal_passed | rate_object(($export.metrics.phase_statuses.tribunal.passed // 0);($export.metrics.phase_statuses.tribunal | count_total)))
  and (.rates.merged | rate_object(($export.metrics.phase_statuses.merge.merged // 0);($export.metrics.phase_statuses.merge | count_total)))
  and (.rates.deployed | rate_object(($export.metrics.phase_statuses.deployment.passed // 0);($export.metrics.phase_statuses.deployment | count_total)))
' "$candidate" >/dev/null; then
  echo "agent-events-export: internal export schema failure" >&2
  exit 3
fi

# shellcheck source=pii-gate.sh
. "$SCRIPT_DIR/pii-gate.sh" || { echo "agent-events-export: PII gate unavailable" >&2; exit 3; }
if pii_hit "$(cat "$candidate")"; then
  echo "agent-events-export: blocked by secret/PII gate" >&2
  exit 3
fi
if jq -r '.. | strings' "$candidate" | grep -qiE '(https?://|file://|(^|[[:space:]])/[^[:space:]]|[A-Za-z]:\\|github\.com|gitlab\.com|/pull/|/issues/)'; then
  echo "agent-events-export: blocked path/URL-shaped value" >&2
  exit 3
fi
if jq -r 'paths(scalars) | map(tostring) | join(".")' "$candidate" \
  | grep -qiE '(^|\.)(project|repository|repo_name|customer|prompt|issue_body|diff|file|filename|path|url|run_id|writer_id|base_sha|result_sha)($|\.)'; then
  echo "agent-events-export: blocked identity-bearing field" >&2
  exit 3
fi

mkdir -p "$(dirname -- "$OUT")"
mv "$candidate" "$OUT"
printf '%s\n' "$OUT"
