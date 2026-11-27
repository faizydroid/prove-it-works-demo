#!/usr/bin/env bash
# create-experiment.sh — flag + keyed variants + metric + experiment. Serves nothing yet.
#
#   bash scripts/create-experiment.sh --flag landing_headline \
#     --control "Run A/B tests from your coding agent." \
#     --variant problem="Stop guessing which version wins. Let your agent prove it." \
#     --event cta_click --name "Landing headline: problem-led vs product-led" \
#     --hypothesis "Problem-led copy lifts CTA clicks by 20% relative within three days." \
#     [--weight problem=50] [--metric-name cta_click] [--direction increase] [--confirm-env "Production"]
#     [--guardrail <event>]...   a metric that should NOT drop (attached as "not_decrease");
#                                re-running with a new --guardrail adds it to the existing experiment
#
# The experiment is created with its rollout at 0%: Flagsmith applies an experiment's rollout as
# soon as it is created, so a non-zero rollout here would serve the variants (without recording
# exposures) before anyone approved the start. start-experiment.sh raises it.
#
# Idempotent: an existing flag / variant key / metric name / unfinished experiment is reused,
# so re-running after a partial failure finishes the job instead of duplicating it.
#
# Output (one line):
#   {"ok":true,"flag":"landing_headline","feature_id":12,"variants":{"problem":34},"metric_id":5,
#    "experiment_id":7,"status":"created","reused":{"flag":false,"metric":false,"experiment":false},
#    "environment":{"name":"Development","key":"...","source":"config"},"dashboard":"..."}
. "$(dirname "$0")/_lib.sh"

FLAG= CONTROL= EVENT= NAME= HYPOTHESIS= METRIC_NAME= DIRECTION=increase CONFIRM_ENV=
ROLLOUT=0
declare -a VARIANTS=() WEIGHTS=() GUARDS=()
while [[ $# -gt 0 ]]; do
  case $1 in
    --flag) FLAG=$2; shift 2 ;;
    --control) CONTROL=$2; shift 2 ;;
    --variant) VARIANTS+=("$2"); shift 2 ;;
    --weight) WEIGHTS+=("$2"); shift 2 ;;
    --guardrail) GUARDS+=("$2"); shift 2 ;;
    --event) EVENT=$2; shift 2 ;;
    --name) NAME=$2; shift 2 ;;
    --hypothesis) HYPOTHESIS=$2; shift 2 ;;
    --rollout) fail "--rollout moved to start-experiment.sh (experiments are created at 0% so nothing is served before the start)." ;;
    --metric-name) METRIC_NAME=$2; shift 2 ;;
    --direction) DIRECTION=$2; shift 2 ;;
    --confirm-env) CONFIRM_ENV=$2; shift 2 ;;
    *) fail "Unknown argument: $1" ;;
  esac
done
[[ -n $FLAG ]] || fail "--flag is required"
[[ -n $CONTROL ]] || fail "--control <value> is required (the flag's own value; what control sees)"
[[ ${#VARIANTS[@]} -ge 1 ]] || fail "At least one --variant key=value is required"
[[ -n $EVENT ]] || fail "--event is required (the conversion event name the code will send; case-sensitive)"
[[ -n $NAME ]] || fail "--name is required (experiment name)"
[[ -n $HYPOTHESIS ]] || fail "--hypothesis is required (one sentence: change, metric, expected size, timeframe)"
[[ $FLAG =~ ^[a-z0-9_]+$ ]] || fail "Flag names should be snake_case: [a-z0-9_]"
[[ $DIRECTION =~ ^(increase|decrease|not_increase|not_decrease)$ ]] || fail "--direction must be increase|decrease|not_increase|not_decrease"
METRIC_NAME=${METRIC_NAME:-$EVENT}
for v in "${VARIANTS[@]}"; do
  [[ $v == *=* ]] || fail "--variant needs key=value, got: $v"
  [[ ${v%%=*} != control ]] || fail "'control' is reserved for the flag's own value; pick another variant key"
  [[ ${v%%=*} =~ ^[a-z0-9_-]+$ ]] || fail "Variant keys should be short and lowercase: [a-z0-9_-], got: ${v%%=*}"
done

check_cli
resolve_context
guard_env "$CONFIRM_ENV"
PROJECT_ID=$(fsq '.id' project get "$PROJECT")

# ---- 1. flag ---------------------------------------------------------------------------------
REUSED_FLAG=true
if ! flagsmith feature get "$FLAG" --json >/dev/null 2>&1; then
  REUSED_FLAG=false
  fs feature create "$FLAG" --value "$CONTROL" --enabled --description "A/B test: $NAME" >/dev/null
fi
FEATURE_ID=$(fsq '.id' feature get "$FLAG")

# ---- 2. variants (every one keyed; an unkeyed variant records no exposures) ----------------------
for v in "${VARIANTS[@]}"; do
  key=${v%%=*}; value=${v#*=}
  existing=$(fsq ".variants[]? | select(.key == \"$key\") | .id" feature get "$FLAG")
  if [[ -z $existing ]]; then
    fs feature variant add "$FLAG" --key "$key" --value "$value" --weight 0 >/dev/null
  fi
done
VARIANT_MAP=$(fs feature get "$FLAG" --jq '[.variants[]? | select(.key != null and .key != "")] | map({(.key): .id}) | add // {}')
for v in "${VARIANTS[@]}"; do
  key=${v%%=*}
  [[ $VARIANT_MAP == *"\"$key\":"* ]] || fail "Variant '$key' was not created on $FLAG." "Check: flagsmith feature variant list $FLAG"
done

# ---- 3. metric (occurrence of <event>, higher is better) -----------------------------------------
METRICS_PATH="api/v1/environments/$ENV_KEY/experiment-metrics/"
LIST='(if type == "array" then . else .results end)[]?'   # paginated or plain list, same jq
REUSED_METRIC=true
METRIC_ID=$(apiq "$LIST | select(.name == \"$METRIC_NAME\") | .id" "${METRICS_PATH}?page_size=200")
if [[ -z $METRIC_ID ]]; then
  REUSED_METRIC=false
  METRIC_ID=$(printf '{"name":%s,"aggregation":"occurrence","direction":"up","definition":{"version":1,"event":%s}}' \
      "$(json_str "$METRIC_NAME")" "$(json_str "$EVENT")" \
    | apiq '.id' "$METRICS_PATH" --input -)
fi
[[ $METRIC_ID =~ ^[0-9]+$ ]] || fail "Could not create or find metric '$METRIC_NAME'."

# Guardrail metrics: one occurrence metric per event, named after the event.
GUARD_JSON="" GUARD_METRICS=""
declare -a GUARD_IDS=()
for g in "${GUARDS[@]+"${GUARDS[@]}"}"; do
  [[ $g != "$EVENT" ]] || fail "--guardrail '$g' is the primary event; pick a metric you don't expect to move."
  gid=$(apiq "$LIST | select(.name == \"$g\") | .id" "${METRICS_PATH}?page_size=200")
  if [[ -z $gid ]]; then
    gid=$(printf '{"name":%s,"aggregation":"occurrence","direction":"up","definition":{"version":1,"event":%s}}' \
        "$(json_str "$g")" "$(json_str "$g")" | apiq '.id' "$METRICS_PATH" --input -)
  fi
  [[ $gid =~ ^[0-9]+$ ]] || fail "Could not create or find guardrail metric '$g'."
  GUARD_IDS+=("$gid")
  GUARD_JSON+="${GUARD_JSON:+,}$(json_str "$g"):$gid"
  GUARD_METRICS+=",{\"metric\":$gid,\"expected_direction\":\"not_decrease\"}"
done

# ---- 4. experiment (created, not started: nothing is served until start-experiment.sh) -----------
EXP_PATH="api/v1/environments/$ENV_KEY/experiments/"
REUSED_EXP=true
EXP_ID=$(apiq "$LIST | select(.feature.id == $FEATURE_ID and .status != \"completed\") | .id" "${EXP_PATH}?page_size=200")
if [[ -z $EXP_ID ]]; then
  REUSED_EXP=false
  # Split: explicit --weight key=pct, else even across control + variants (control takes the remainder).
  n=$(( ${#VARIANTS[@]} + 1 ))
  share=$(( 100 / n ))
  MV_JSON=""
  for v in "${VARIANTS[@]}"; do
    key=${v%%=*}; pct=$share
    for w in "${WEIGHTS[@]+"${WEIGHTS[@]}"}"; do [[ ${w%%=*} == "$key" ]] && pct=${w#*=}; done
    id=$(printf '%s' "$VARIANT_MAP" | sed -E "s/.*\"$key\":([0-9]+).*/\1/")
    MV_JSON+="${MV_JSON:+,}{\"multivariate_feature_option\":$id,\"percentage_allocation\":$pct}"
  done
  BODY=$(printf '{"feature":%s,"name":%s,"hypothesis":%s,"metrics":[{"metric":%s,"expected_direction":%s}%s],"experiment_rollout":{"enabled":true,"rollout_percentage":%s,"feature_state_value":{"type":"string","value":%s},"multivariate_feature_state_values":[%s]}}' \
    "$FEATURE_ID" "$(json_str "$NAME")" "$(json_str "$HYPOTHESIS")" "$METRIC_ID" "$(json_str "$DIRECTION")" \
    "$GUARD_METRICS" "$ROLLOUT" "$(json_str "$CONTROL")" "$MV_JSON")
  EXP_ID=$(printf '%s' "$BODY" | apiq '.id' "$EXP_PATH" --input -)
fi
[[ $EXP_ID =~ ^[0-9]+$ ]] || fail "Could not create or find the experiment."

# A reused experiment (even a running one) gets any guardrail it doesn't have yet.
if [[ $REUSED_EXP == true && ${#GUARD_IDS[@]} -gt 0 ]]; then
  ATTACHED=$(apiq '[.[].metric] | map(tostring) | join(",")' "${EXP_PATH}${EXP_ID}/metrics/")
  for gid in "${GUARD_IDS[@]}"; do
    [[ ",$ATTACHED," == *",$gid,"* ]] && continue
    printf '{"metric":%s,"expected_direction":"not_decrease"}' "$gid" | api "${EXP_PATH}${EXP_ID}/metrics/" --input - >/dev/null
  done
fi
STATUS=$(apiq '.status' "${EXP_PATH}${EXP_ID}/")

mkdir -p "$STATE_DIR"
printf '{"flag":%s,"feature_id":%s,"variants":%s,"metric_id":%s,"experiment_id":%s,"env":%s,"project_id":%s}\n' \
  "$(json_str "$FLAG")" "$FEATURE_ID" "$VARIANT_MAP" "$METRIC_ID" "$EXP_ID" "$(json_str "$ENV_KEY")" "$PROJECT_ID" > "$STATE_DIR/experiment-$EXP_ID.json"

printf '{"ok":true,"flag":%s,"feature_id":%s,"variants":%s,"metric_id":%s,"guardrails":{%s},"experiment_id":%s,"status":%s,"reused":{"flag":%s,"metric":%s,"experiment":%s},"environment":%s,"dashboard":%s}\n' \
  "$(json_str "$FLAG")" "$FEATURE_ID" "$VARIANT_MAP" "$METRIC_ID" "$GUARD_JSON" "$EXP_ID" "$(json_str "$STATUS")" \
  "$REUSED_FLAG" "$REUSED_METRIC" "$REUSED_EXP" "$(env_json)" \
  "$(json_str "$DASHBOARD/project/$PROJECT_ID/environment/$ENV_KEY/experiments/$EXP_ID")"
