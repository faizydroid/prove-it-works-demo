#!/usr/bin/env bash
# rollout-winner.sh — complete the experiment and decide what the flag serves from now on.
#
#   bash scripts/rollout-winner.sh --id 7 --variant ai            # ship the winning variant to 100%
#   bash scripts/rollout-winner.sh --id 7 --decision control      # keep control (always allowed)
#   bash scripts/rollout-winner.sh --id 7 --decision disable      # turn the flag off for everyone
#   bash scripts/rollout-winner.sh --id 7 --variant ai --override "<the human's exact words>"
#
# Guard rails (not negotiable from the command line):
#   - a variant ships only when results.sh says verdict=winner for THAT variant
#   - never while "collecting" and never on a sample-ratio mismatch
#   - --override is accepted only for verdict=inconclusive or verdict=guardrail (a winner that hurt
#     a guardrail metric), must carry the human's words, and is written into the rollback file
#     next to the numbers it overrode
#   - the pre-rollout flag state is saved first and the one-line rollback command is printed
# Completing is final: results freeze, the flag unlocks, the environment default serves the decision.
#
# Output:
#   {"ok":true,"experiment_id":7,"status":"completed","flag":"landing_headline","decision":"variant",
#    "serving":"ai","verdict":"winner","rollback":"flagsmith flag update landing_headline --weight ai=0",
#    "rollback_file":".prove-it-works/rollback-landing_headline-20261129T1200Z.json","dashboard":"..."}
. "$(dirname "$0")/_lib.sh"

ID= VARIANT= DECISION= OVERRIDE= CONFIRM_ENV=
while [[ $# -gt 0 ]]; do
  case $1 in
    --id) ID=$2; shift 2 ;;
    --variant) VARIANT=$2; DECISION=variant; shift 2 ;;
    --decision) DECISION=$2; shift 2 ;;
    --override) OVERRIDE=$2; shift 2 ;;
    --confirm-env) CONFIRM_ENV=$2; shift 2 ;;
    *) fail "Unknown argument: $1" ;;
  esac
done
[[ $ID =~ ^[0-9]+$ ]] || fail "--id <experiment id> is required"
[[ $DECISION =~ ^(variant|control|disable)$ ]] || fail "Pass --variant <key>, --decision control, or --decision disable"
[[ $DECISION != variant || -n $VARIANT ]] || fail "--variant <key> is required to roll out a variant"
[[ $DECISION == variant || -z $OVERRIDE ]] || fail "--override only applies to --variant"

check_cli
resolve_context
guard_env "$CONFIRM_ENV"
PROJECT_ID=$(fsq '.id' project get "$PROJECT")
EXP="api/v1/environments/$ENV_KEY/experiments/$ID/"
LINK="$DASHBOARD/project/$PROJECT_ID/environment/$ENV_KEY/experiments/$ID"

STATUS=$(apiq '.status' "$EXP")
FLAG=$(apiq '.feature.name' "$EXP")
case $STATUS in
  running|paused) ;;
  completed) fail "Experiment $ID is already completed." "Check what the flag serves: flagsmith flag get $FLAG" ;;
  *) fail "Experiment $ID is '$STATUS'; only a running or paused experiment can be completed." ;;
esac

# ---- the verdict decides, not the caller ----------------------------------------------------------
RES=$(bash "$(dirname "$0")/results.sh" --id "$ID") || { printf '%s\n' "$RES" >&3; exit 1; }
[[ $RES =~ \"verdict\":\"([a-z_]+)\" ]] && VERDICT=${BASH_REMATCH[1]} || VERDICT=unknown
[[ $RES =~ \"winner\":\"([a-z0-9_-]+)\" ]] && WINNER=${BASH_REMATCH[1]} || WINNER=
[[ $RES =~ \"candidate\":\"([a-z0-9_-]+)\" ]] && CANDIDATE=${BASH_REMATCH[1]} || CANDIDATE=
[[ $RES =~ \"reason\":\"([^\"]*)\" ]] && REASON=${BASH_REMATCH[1]} || REASON=

if [[ $DECISION == variant ]]; then
  case $VERDICT in
    winner)
      [[ $WINNER == "$VARIANT" ]] || fail "Refusing: the winner is '$WINNER', not '$VARIANT'. $REASON"
      ;;
    inconclusive)
      [[ -n $OVERRIDE ]] || fail "Refusing: results are inconclusive, so '$VARIANT' has not been shown to beat control. $REASON" \
        "Keep collecting, or --decision control. If the human explicitly accepts an unproven variant, re-run with --override \"<their exact words>\"."
      ;;
    guardrail)
      [[ $CANDIDATE == "$VARIANT" ]] || fail "Refusing: the primary-metric leader is '$CANDIDATE', not '$VARIANT'. $REASON"
      [[ -n $OVERRIDE ]] || fail "Refusing: '$VARIANT' won on the primary metric but hurt a guardrail. $REASON" \
        "Show the human both numbers. Only with their explicit acceptance of the trade-off, re-run with --override \"<their exact words>\"."
      ;;
    collecting|no_results)
      fail "Refusing: not enough data yet ($VERDICT). $REASON" "Keep the experiment running; --override is not accepted here."
      ;;
    srm)
      fail "Refusing: sample ratio mismatch. These numbers cannot be trusted; fix the split before deciding. $REASON" "--override is not accepted here."
      ;;
    control_wins)
      fail "Refusing: control beat every variant. $REASON" "Use --decision control to end the experiment and keep control."
      ;;
    *) fail "Refusing: could not read a verdict from results.sh ($VERDICT)." ;;
  esac
  VARIANT_ID=$(apiq ".feature.multivariate_options[]? | select(.key == \"$VARIANT\") | .id" "$EXP")
  [[ $VARIANT_ID =~ ^[0-9]+$ ]] || fail "Variant '$VARIANT' not found on $FLAG." "flagsmith feature variant list $FLAG"
fi

# ---- save the state we are about to change, then the rollback command -----------------------------
mkdir -p "$STATE_DIR"
TS=$(date -u +%Y%m%dT%H%M%SZ)
RB_FILE="$STATE_DIR/rollback-$FLAG-$TS.json"
BEFORE=$(fs flag get "$FLAG" --json)
case $DECISION in
  variant) ROLLBACK="flagsmith flag update $FLAG --weight $VARIANT=0" ;;   # control's own value serves again
  control) ROLLBACK="(nothing to roll back: control is what served before)" ;;
  disable) ROLLBACK="flagsmith flag enable $FLAG" ;;
esac
printf '{"experiment_id":%s,"flag":%s,"decision":%s,"variant":%s,"verdict":%s,"override":%s,"saved_at":%s,"rollback":%s,"results":%s,"flag_before":%s}\n' \
  "$ID" "$(json_str "$FLAG")" "$(json_str "$DECISION")" "$(json_str "$VARIANT")" "$(json_str "$VERDICT")" \
  "$(json_str "$OVERRIDE")" "$(json_str "$TS")" "$(json_str "$ROLLBACK")" "$RES" "$BEFORE" > "$RB_FILE"

# ---- complete ------------------------------------------------------------------------------------
if [[ $DECISION == variant ]]; then
  BODY=$(printf '{"rollout_decision":"variant","rollout_variant":%s}' "$VARIANT_ID")
else
  BODY=$(printf '{"rollout_decision":"%s"}' "$DECISION")
fi
printf '%s' "$BODY" | api "${EXP}complete/" --input - >/dev/null

STATUS=$(apiq '.status' "$EXP")
[[ $STATUS == completed ]] || fail "Complete was accepted but status is '$STATUS'." "Check $LINK"

# What does the flag serve now? enabled + the 100% variant, or control's value, or off.
SERVING=$(fs flag get "$FLAG" --jq 'if .enabled != true then "off" else ((.variants // []) | map(select(.weight >= 100)) | .[0].key // "control") end')

printf '{"ok":true,"experiment_id":%s,"status":"completed","flag":%s,"decision":%s,"serving":%s,"verdict":%s,"override":%s,"rollback":%s,"rollback_file":%s,"environment":%s,"dashboard":%s}\n' \
  "$ID" "$(json_str "$FLAG")" "$(json_str "$DECISION")" "$(json_str "$SERVING")" "$(json_str "$VERDICT")" \
  "$(json_str "$OVERRIDE")" "$(json_str "$ROLLBACK")" "$(json_str "$RB_FILE")" "$(env_json)" "$(json_str "$LINK")"
