#!/usr/bin/env bash
# start-experiment.sh — start the experiment and enrol traffic. From here the flag is locked.
#
#   bash scripts/start-experiment.sh --id 7 [--rollout 100] [--confirm-env "Production"]
#
# create-experiment.sh leaves the rollout at 0% (an unstarted experiment would otherwise already
# serve its variants). This starts the experiment, then raises the rollout from 0 to --rollout.
# A rollout that is already above 0 is left alone: changing it mid-run hurts validity.
#
# Output: {"ok":true,"experiment_id":7,"status":"running","rollout":100,"started_at":"...",
#          "flag":"landing_headline","environment":{...},"dashboard":"..."}
. "$(dirname "$0")/_lib.sh"

ID= ROLLOUT=100 CONFIRM_ENV=
while [[ $# -gt 0 ]]; do
  case $1 in
    --id) ID=$2; shift 2 ;;
    --rollout) ROLLOUT=$2; shift 2 ;;
    --confirm-env) CONFIRM_ENV=$2; shift 2 ;;
    *) fail "Unknown argument: $1" ;;
  esac
done
[[ $ID =~ ^[0-9]+$ ]] || fail "--id <experiment id> is required"
[[ $ROLLOUT =~ ^[0-9]+(\.[0-9]+)?$ ]] && awk "BEGIN{exit !($ROLLOUT > 0 && $ROLLOUT <= 100)}" \
  || fail "--rollout must be a percentage above 0 and at most 100"

check_cli
resolve_context
guard_env "$CONFIRM_ENV"
PROJECT_ID=$(fsq '.id' project get "$PROJECT")
EXP="api/v1/environments/$ENV_KEY/experiments/$ID/"

IFS=$'\t' read -r STATUS FLAG <<<"$(fs api "$EXP" --jq '"\(.status)\t\(.feature.name)"')"
case $STATUS in
  created|paused) api "${EXP}start/" -X POST >/dev/null ;;
  running) ;;  # already running: idempotent
  completed) fail "Experiment $ID is completed; results are final and it cannot be restarted." "Create a new experiment with create-experiment.sh" ;;
  *) fail "Experiment $ID has unexpected status '$STATUS'." ;;
esac

# Enrol traffic: 0 -> target, keeping the stored value, variants and split.
CURRENT=$(apiq '.experiment_rollout.rollout_percentage // 0' "$EXP")
if awk "BEGIN{exit !($CURRENT == 0)}"; then
  fs api "$EXP" --jq ".experiment_rollout | .rollout_percentage = $ROLLOUT | del(.audience)" \
    | fs api "${EXP}rollout/" -X PATCH --input - --json >/dev/null
fi

IFS=$'\t' read -r STATUS STARTED NOW <<<"$(fs api "$EXP" --jq '"\(.status)\t\(.started_at // "")\t\(.experiment_rollout.rollout_percentage // 0)"')"
[[ $STATUS == running ]] || fail "Start was accepted but status is '$STATUS', not running."

printf '{"ok":true,"experiment_id":%s,"status":"running","rollout":%s,"started_at":%s,"flag":%s,"environment":%s,"dashboard":%s}\n' \
  "$ID" "$NOW" "$(json_str "$STARTED")" "$(json_str "$FLAG")" "$(env_json)" \
  "$(json_str "$DASHBOARD/project/$PROJECT_ID/environment/$ENV_KEY/experiments/$ID")"
