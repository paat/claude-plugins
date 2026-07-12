#!/usr/bin/env bash
# Aggregate multiple already-sanitized delivery exports without project identity.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
OUT="" INPUTS=()

usage() {
  echo "usage: agent-events-aggregate.sh --out FILE EXPORT.json [EXPORT.json ...]" >&2
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --out) [ "$#" -ge 2 ] || usage; OUT="$2"; shift 2 ;;
    --*) usage ;;
    *) INPUTS+=("$1"); shift ;;
  esac
done
[ -n "$OUT" ] && [ "${#INPUTS[@]}" -gt 0 ] || usage

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
candidate="$tmpdir/aggregate.json"

# shellcheck source=pii-gate.sh
. "$SCRIPT_DIR/pii-gate.sh" || { echo "agent-events-aggregate: PII gate unavailable" >&2; exit 3; }

for input in "${INPUTS[@]}"; do
  [ -f "$input" ] || { echo "agent-events-aggregate: missing export: $input" >&2; exit 2; }
  if ! jq -e '
    def uint: type == "number" and . >= 0 and floor == .;
    def exact_keys($allowed): type == "object" and ((keys | sort) == ($allowed | sort));
    def countmap($allowed):
      type == "object" and
      (to_entries | all(.[]; . as $entry | (($allowed | index($entry.key)) != null) and
        ($entry.value | uint)));
    def count_total: if type == "object" then ([.[]] | add // 0) else -1 end;
    def routing_versions:
      type == "object" and (to_entries | all(.[]; (.key | test("^[0-9]+$")) and (.value | uint)));
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
    def profiles: ["mechanical","light","standard","deep","other"];
    def outcomes: ["incomplete","success","failure","blocked","skipped","no-op","escalated","cancelled","other"];
    def providers: ["openai","anthropic","google","xai","local","other"];
    def models: ["gpt-5.6-sol","gpt-5.6-terra","claude-fable","claude-opus","claude-sonnet","claude-haiku","gemini","grok","other"];
    def efforts: ["low","medium","high","xhigh","max","other"];
    def statuses: ["not_run","not_started","not_created","not_applicable","not_needed","pending","passed","failed","blocked","skipped","incomplete","draft","open","closed","merged","rolled_back","cancelled","success","other"];
    . as $export
    | exact_keys(["kind","metrics","rates","run_count","sample_count","schema_version"])
    and .schema_version == 1 and .kind == "delivery-evaluation-export"
    and (.sample_count | uint) and (.run_count | uint) and .run_count <= .sample_count
    and (.metrics | exact_keys([
      "cached_input_tokens","cost_microunits","duration_ms","efforts","fallback_count","input_tokens","models","outcomes",
      "output_tokens","phase_statuses","profiles","providers","routing_schema_versions","tokens_available_after","tokens_available_before"
    ]))
    and (.metrics.phase_statuses | exact_keys(["checks","deployment","merge","pr","qa","rollback","tribunal"]))
    and (.metrics.providers | exact_keys(["effective","requested"]))
    and (.metrics.models | exact_keys(["effective","requested"]))
    and (.metrics.efforts | exact_keys(["effective","requested"]))
    and (.metrics.profiles | countmap(profiles))
    and (.metrics.outcomes | countmap(outcomes))
    and (.metrics.routing_schema_versions | routing_versions)
    and (.metrics.providers.requested | countmap(providers))
    and (.metrics.providers.effective | countmap(providers))
    and (.metrics.models.requested | countmap(models))
    and (.metrics.models.effective | countmap(models))
    and (.metrics.efforts.requested | countmap(efforts))
    and (.metrics.efforts.effective | countmap(efforts))
    and ([.metrics.phase_statuses[] | countmap(statuses)] | all)
    and (.metrics.fallback_count | uint) and .metrics.fallback_count <= .sample_count
    and (.metrics.duration_ms | uint_values) and (.metrics.duration_ms | length) <= .sample_count
    and (.metrics.tokens_available_before | uint_values) and (.metrics.tokens_available_before | length) <= .sample_count
    and (.metrics.tokens_available_after | uint_values) and (.metrics.tokens_available_after | length) <= .sample_count
    and (.metrics.input_tokens | uint_values) and (.metrics.input_tokens | length) <= .sample_count
    and (.metrics.output_tokens | uint_values) and (.metrics.output_tokens | length) <= .sample_count
    and (.metrics.cached_input_tokens | uint_values) and (.metrics.cached_input_tokens | length) <= .sample_count
    and (.metrics.cost_microunits | uint_values) and (.metrics.cost_microunits | length) <= .sample_count
    and (.metrics.outcomes | count_total) == .sample_count
    and (.metrics.routing_schema_versions | count_total) == .sample_count
    and (.metrics.profiles | count_total) <= .sample_count
    and (.metrics.providers.requested | count_total) <= .sample_count
    and (.metrics.providers.effective | count_total) <= .sample_count
    and (.metrics.models.requested | count_total) <= .sample_count
    and (.metrics.models.effective | count_total) <= .sample_count
    and (.metrics.efforts.requested | count_total) <= .sample_count
    and (.metrics.efforts.effective | count_total) <= .sample_count
    and ([.metrics.phase_statuses[] | count_total <= $export.sample_count] | all)
    and (.rates | exact_keys(["checks_passed","deployed","merged","qa_passed","success","tribunal_passed"]))
    and (.rates.success | rate_object(($export.metrics.outcomes.success // 0);$export.sample_count))
    and (.rates.checks_passed | rate_object(($export.metrics.phase_statuses.checks.passed // 0);($export.metrics.phase_statuses.checks | count_total)))
    and (.rates.qa_passed | rate_object(($export.metrics.phase_statuses.qa.passed // 0);($export.metrics.phase_statuses.qa | count_total)))
    and (.rates.tribunal_passed | rate_object(($export.metrics.phase_statuses.tribunal.passed // 0);($export.metrics.phase_statuses.tribunal | count_total)))
    and (.rates.merged | rate_object(($export.metrics.phase_statuses.merge.merged // 0);($export.metrics.phase_statuses.merge | count_total)))
    and (.rates.deployed | rate_object(($export.metrics.phase_statuses.deployment.passed // 0);($export.metrics.phase_statuses.deployment | count_total)))
  ' "$input" >/dev/null; then
    echo "agent-events-aggregate: export schema, count, or rate validation failed: $input" >&2
    exit 3
  fi
  if pii_hit "$(cat "$input")"; then
    echo "agent-events-aggregate: export blocked by secret/PII gate" >&2
    exit 3
  fi
  if jq -r '.. | strings' "$input" | grep -qiE '(https?://|file://|(^|[[:space:]])/[^[:space:]]|[A-Za-z]:\\|github\.com|gitlab\.com|/pull/|/issues/)'; then
    echo "agent-events-aggregate: export contains a path/URL-shaped value" >&2
    exit 3
  fi
  if jq -r '.. | objects | keys[]' "$input" | grep -qEv '^[A-Za-z0-9_.:-]+$'; then
    echo "agent-events-aggregate: export contains a non-code key" >&2
    exit 3
  fi
done

jq -s '
  def add_counts($a;$b):
    reduce ($b | to_entries[]) as $e ($a; .[$e.key] = ((.[$e.key] // 0) + $e.value));
  def total($o): [$o[]] | add // 0;
  def rate($n;$d): if $d == 0 then null else (($n * 1000000 / $d | floor) / 1000000) end;
  reduce .[] as $e (
    {
      schema_version:1,kind:"delivery-evaluation-aggregate",export_count:0,sample_count:0,run_count:0,
      metrics:{
        profiles:{},routing_schema_versions:{},outcomes:{},providers:{requested:{},effective:{}},models:{requested:{},effective:{}},efforts:{requested:{},effective:{}},
        phase_statuses:{checks:{},qa:{},tribunal:{},pr:{},merge:{},deployment:{},rollback:{}},fallback_count:0,
        duration_ms:[],tokens_available_before:[],tokens_available_after:[],input_tokens:[],output_tokens:[],cached_input_tokens:[],cost_microunits:[]
      },rates:{}
    };
    .export_count += 1
    | .sample_count += $e.sample_count | .run_count += $e.run_count
    | .metrics.profiles = add_counts(.metrics.profiles;$e.metrics.profiles)
    | .metrics.routing_schema_versions = add_counts(.metrics.routing_schema_versions;$e.metrics.routing_schema_versions)
    | .metrics.outcomes = add_counts(.metrics.outcomes;$e.metrics.outcomes)
    | .metrics.providers.requested = add_counts(.metrics.providers.requested;$e.metrics.providers.requested)
    | .metrics.providers.effective = add_counts(.metrics.providers.effective;$e.metrics.providers.effective)
    | .metrics.models.requested = add_counts(.metrics.models.requested;$e.metrics.models.requested)
    | .metrics.models.effective = add_counts(.metrics.models.effective;$e.metrics.models.effective)
    | .metrics.efforts.requested = add_counts(.metrics.efforts.requested;$e.metrics.efforts.requested)
    | .metrics.efforts.effective = add_counts(.metrics.efforts.effective;$e.metrics.efforts.effective)
    | .metrics.phase_statuses.checks = add_counts(.metrics.phase_statuses.checks;$e.metrics.phase_statuses.checks)
    | .metrics.phase_statuses.qa = add_counts(.metrics.phase_statuses.qa;$e.metrics.phase_statuses.qa)
    | .metrics.phase_statuses.tribunal = add_counts(.metrics.phase_statuses.tribunal;$e.metrics.phase_statuses.tribunal)
    | .metrics.phase_statuses.pr = add_counts(.metrics.phase_statuses.pr;$e.metrics.phase_statuses.pr)
    | .metrics.phase_statuses.merge = add_counts(.metrics.phase_statuses.merge;$e.metrics.phase_statuses.merge)
    | .metrics.phase_statuses.deployment = add_counts(.metrics.phase_statuses.deployment;$e.metrics.phase_statuses.deployment)
    | .metrics.phase_statuses.rollback = add_counts(.metrics.phase_statuses.rollback;$e.metrics.phase_statuses.rollback)
    | .metrics.fallback_count += $e.metrics.fallback_count
    | .metrics.duration_ms += $e.metrics.duration_ms
    | .metrics.tokens_available_before += $e.metrics.tokens_available_before
    | .metrics.tokens_available_after += $e.metrics.tokens_available_after
    | .metrics.input_tokens += $e.metrics.input_tokens
    | .metrics.output_tokens += $e.metrics.output_tokens
    | .metrics.cached_input_tokens += $e.metrics.cached_input_tokens
    | .metrics.cost_microunits += $e.metrics.cost_microunits
  )
  | .metrics.duration_ms |= sort
  | .metrics.tokens_available_before |= sort
  | .metrics.tokens_available_after |= sort
  | .metrics.input_tokens |= sort
  | .metrics.output_tokens |= sort
  | .metrics.cached_input_tokens |= sort
  | .metrics.cost_microunits |= sort
  | .rates = {
      success:{numerator:(.metrics.outcomes.success // 0),denominator:.sample_count,value:rate((.metrics.outcomes.success // 0);.sample_count)},
      checks_passed:{numerator:(.metrics.phase_statuses.checks.passed // 0),denominator:total(.metrics.phase_statuses.checks),value:rate((.metrics.phase_statuses.checks.passed // 0);total(.metrics.phase_statuses.checks))},
      qa_passed:{numerator:(.metrics.phase_statuses.qa.passed // 0),denominator:total(.metrics.phase_statuses.qa),value:rate((.metrics.phase_statuses.qa.passed // 0);total(.metrics.phase_statuses.qa))},
      tribunal_passed:{numerator:(.metrics.phase_statuses.tribunal.passed // 0),denominator:total(.metrics.phase_statuses.tribunal),value:rate((.metrics.phase_statuses.tribunal.passed // 0);total(.metrics.phase_statuses.tribunal))},
      merged:{numerator:(.metrics.phase_statuses.merge.merged // 0),denominator:total(.metrics.phase_statuses.merge),value:rate((.metrics.phase_statuses.merge.merged // 0);total(.metrics.phase_statuses.merge))},
      deployed:{numerator:(.metrics.phase_statuses.deployment.passed // 0),denominator:total(.metrics.phase_statuses.deployment),value:rate((.metrics.phase_statuses.deployment.passed // 0);total(.metrics.phase_statuses.deployment))}
    }
' "${INPUTS[@]}" > "$candidate"

if pii_hit "$(cat "$candidate")"; then
  echo "agent-events-aggregate: aggregate blocked by secret/PII gate" >&2
  exit 3
fi
mkdir -p "$(dirname -- "$OUT")"
mv "$candidate" "$OUT"
printf '%s\n' "$OUT"
