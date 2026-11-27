#!/usr/bin/env bash
# results.sh — the verdict, computed from Flagsmith's Bayesian results, as one line.
#
#   bash scripts/results.sh --id 7 [--refresh] [--metric <metric id>]
#
#   --refresh  asks Flagsmith to recompute first (allowed once per 5 minutes) and waits up to
#              ~90s for the new numbers. If throttled, the current numbers are returned with
#              "retry_after_s" so the caller can wait instead of looping.
#
# Output:
#   {"ok":true,"experiment_id":7,"status":"running","flag":"landing_headline","as_of":"...",
#    "is_final":false,"srm_p_value":0.83,"srm_warning":false,
#    "variants":{"control":{"n":312,"conversions":25,"rate":0.0801},
#                "ai":{"n":305,"conversions":34,"rate":0.1115,"lift":0.392,"ci":[0.05,0.72],"chance_to_win":0.97}},
#    "verdict":"winner","winner":"ai","reason":"ai: 97% chance to beat control (+39% lift, 95% CI +5%..+72%)",
#    "dashboard":"https://app.flagsmith.com/project/1/environment/ser.xxx/experiments/7"}
#
# verdict:
#   no_results    nothing computed yet -> run with --refresh
#   collecting    under 50 identities or 5 conversions in some variant -> keep running
#   srm           traffic did not split as configured (p < 0.001) -> do NOT act on these numbers
#   winner        a variant has >= 95% chance to beat control and its interval excludes 0
#   guardrail     it would be a winner, but it clearly hurt a guardrail metric -> human decides
#   control_wins  every variant has <= 5% chance to beat control and its interval excludes 0
#   inconclusive  anything else -> keep running, or stop and keep control
# guardrails: [{name, expected:"not_decrease", status: ok|collecting|harmed, harmed_by, variants}]
. "$(dirname "$0")/_lib.sh"

ID= REFRESH=false METRIC_ID=
while [[ $# -gt 0 ]]; do
  case $1 in
    --id) ID=$2; shift 2 ;;
    --refresh) REFRESH=true; shift ;;
    --metric) METRIC_ID=$2; shift 2 ;;
    *) fail "Unknown argument: $1" ;;
  esac
done
[[ $ID =~ ^[0-9]+$ ]] || fail "--id <experiment id> is required"

check_cli
resolve_context
PROJECT_ID=$(fsq '.id' project get "$PROJECT")
EXP="api/v1/environments/$ENV_KEY/experiments/$ID/"

# One call: status, flag name, the configured split (for the SRM check) and the metrics' roles.
META=$(fs api "$EXP" --jq '
  (.feature.multivariate_options // []) as $o
  | [(.experiment_rollout.multivariate_feature_state_values // [])[]
      | .multivariate_feature_option as $id
      | {key: ([$o[] | select(.id == $id) | .key][0] // "?"), value: (.percentage_allocation / 100)}] as $mv
  | [(.metrics // [])[] | {id: .metric, name: .metric_name, dir: .expected_direction, direction}] as $mm
  | "\(.status)\t\(.feature.name)\t\(($mv | from_entries) + {control: (1 - ([$mv[].value] | add // 0))} | tojson)\t\($mm | tojson)"')
IFS=$'\t' read -r STATUS FLAG EXPECTED MMETA <<<"$META"
[[ $EXPECTED == \{* ]] || EXPECTED='{}'
[[ $MMETA == \[* ]] || MMETA='[]'
[[ $STATUS != created ]] && [[ -n $STATUS ]] || fail "Experiment $ID has not started (status: $STATUS); there are no results yet." "Run start-experiment.sh --id $ID first"

RETRY_JSON=""
if [[ $REFRESH == true ]]; then
  prev=$(apiq '.results.as_of // ""' "${EXP}results/")
  if flagsmith api "${EXP}results/refresh/" -X POST --json >/dev/null 2>"$PIW_TMP/err"; then
    for _ in $(seq 1 18); do
      sleep 5
      cur=$(apiq '.results.as_of // ""' "${EXP}results/")
      [[ -n $cur && $cur != "$prev" ]] && break
    done
  else
    err=$(trim_err <"$PIW_TMP/err")
    if [[ $err =~ ([0-9]+)\ second ]]; then
      RETRY_JSON=",\"retry_after_s\":${BASH_REMATCH[1]}"
    elif [[ $err == *final* ]]; then
      : # completed experiment: results are frozen, nothing to refresh
    else
      fail "Refresh failed: $err"
    fi
  fi
fi

# Judge on --metric <id>, else the first metric expected to increase/decrease (the hypothesis metric).
# Every other metric is reported as a guardrail.
[[ -z $METRIC_ID || $METRIC_ID =~ ^[0-9]+$ ]] || fail "--metric must be a metric id"
SUMMARY=$(api "${EXP}results/" --jq "def primary_metric_id: ${METRIC_ID:-null};
def expected: $EXPECTED;
def metric_meta: $MMETA;
$(cat "$(dirname "$0")/results.jq")")

INNER=${SUMMARY#\{}; INNER=${INNER%\}}   # splice the jq object into ours
printf '{"ok":true,"experiment_id":%s,"status":%s,"flag":%s%s,%s,"dashboard":%s}\n' \
  "$ID" "$(json_str "$STATUS")" "$(json_str "$FLAG")" "$RETRY_JSON" "$INNER" \
  "$(json_str "$DASHBOARD/project/$PROJECT_ID/environment/$ENV_KEY/experiments/$ID")"
