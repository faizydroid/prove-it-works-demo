#!/usr/bin/env bash
# preflight.sh — read-only check that an experiment can be run from here.
#
#   bash scripts/preflight.sh [--enable-warehouse]
#
# Output (one line):
#   {"ok":true,"cli":"v2.0.0","user":"me@x.com","project":{"id":1,"name":"toggle-wars"},
#    "environment":{"key":"abc123","name":"Development","source":"config","production_like":false},
#    (source: config = flagsmith.json, env = FLAGSMITH_ENVIRONMENT, flag = -e)
#    "warehouse":{"status":"connected","events":1234,"event_names":3},
#    "dashboard":"https://app.flagsmith.com/project/1/environment/ser.xxx"}
#
# warehouse.status: connected | pending_connection | created | errored | none
#   created / pending_connection / connected -> events are accepted, proceed
#            (Cloud environments get a Flagsmith-managed warehouse in "created" state; the first
#             event from the app moves it to connected)
#   none  -> no warehouse. Re-run with --enable-warehouse to create the Flagsmith-managed one
#            (a change to the environment: ask the human first), or follow
#            https://docs.flagsmith.com/experimentation/connect-a-warehouse
#   errored -> show the human `status_detail`; stop.
. "$(dirname "$0")/_lib.sh"

ENABLE_WH=false
for a in "$@"; do case $a in --enable-warehouse) ENABLE_WH=true ;; *) fail "Unknown argument: $a" ;; esac; done

check_cli
CLI_VERSION=$(flagsmith --version 2>/dev/null | sed -E 's/^flagsmith version //')

# Logged in? auth status fails fast when not.
AUTH=$(flagsmith auth status --json 2>"$PIW_TMP/err") || fail "Not logged in: $(trim_err <"$PIW_TMP/err")" "Run: flagsmith login   (self-hosted: also set FLAGSMITH_API_URL; CI: set FLAGSMITH_API_KEY)"
USER_ID=$(fsq '.identity.email // .identity.username // .email // .user // .identity // "?"' auth status)

resolve_context

IFS=$'\t' read -r PROJECT_ID PROJECT_NAME <<<"$(fs project get "$PROJECT" --jq '"\(.id)\t\(.name)"')"
PROD_LIKE=$(production_like "$ENV_NAME")

WH_PATH="api/v1/environments/$ENV_KEY/warehouse-connections/"
WH_COUNT=$(apiq 'length' "$WH_PATH")

if [[ ${WH_COUNT:-0} -eq 0 && $ENABLE_WH == true ]]; then
  guard_env "${PIW_CONFIRM_ENV:-}"   # creating a warehouse is a write; production needs PIW_CONFIRM_ENV=<name>
  WH_ID=$(apiq '.id' "$WH_PATH" -f warehouse_type=flagsmith -f name=Flagsmith)
  # "Send your first event": flips the card to pending_connection; it becomes connected
  # when the first real event lands (can take a while on the managed warehouse).
  api "${WH_PATH}${WH_ID}/test-warehouse-connection/" -X POST >/dev/null
  WH_COUNT=1
fi

if [[ ${WH_COUNT:-0} -eq 0 ]]; then
  WH_JSON='{"status":"none"}'
else
  WH_JSON=$(api "$WH_PATH" --jq '.[0] | {status, type: .warehouse_type, events: (.total_events_received // 0), event_names: (.unique_events_count // 0), detail: .status_detail}')
fi

printf '{"ok":true,"cli":%s,"user":%s,"project":{"id":%s,"name":%s},"environment":{"key":%s,"name":%s,"source":%s,"production_like":%s},"warehouse":%s,"dashboard":%s}\n' \
  "$(json_str "$CLI_VERSION")" "$(json_str "$USER_ID")" "$PROJECT_ID" "$(json_str "$PROJECT_NAME")" \
  "$(json_str "$ENV_KEY")" "$(json_str "$ENV_NAME")" "$(json_str "$ENV_SOURCE")" "$PROD_LIKE" "$WH_JSON" \
  "$(json_str "$DASHBOARD/project/$PROJECT_ID/environment/$ENV_KEY")"
