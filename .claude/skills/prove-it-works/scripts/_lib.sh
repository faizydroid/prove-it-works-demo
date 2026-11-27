#!/usr/bin/env bash
# Shared helpers for prove-it-works scripts. Source it, don't run it.
#
# Contract every script keeps: exactly ONE JSON line on stdout.
#   success -> {"ok":true, ...}            exit 0
#   failure -> {"ok":false,"error":"..."}  exit 1
# No API payload ever reaches the agent unfiltered; extraction happens here with the CLI's
# built-in --jq, so the only dependencies are bash and the Flagsmith CLI (v2+).
set -euo pipefail
shopt -s inherit_errexit 2>/dev/null || true   # bash 4.4+: failures inside $(...) stop the script too

exec 3>&1   # fd 3 = the real stdout, so fail() is visible even from inside $(...)

json_str() { # json_str <text> -> "escaped"
  local s=$1
  s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\n'/\\n}; s=${s//$'\r'/\\r}; s=${s//$'\t'/\\t}
  printf '"%s"' "$s"
}

fail() { # fail <message> [hint]
  local msg=$1 hint=${2:-}
  if [[ -n $hint ]]; then
    printf '{"ok":false,"error":%s,"hint":%s}\n' "$(json_str "$msg")" "$(json_str "$hint")" >&3
  else
    printf '{"ok":false,"error":%s}\n' "$(json_str "$msg")" >&3
  fi
  exit 1
}

need() { command -v "$1" >/dev/null 2>&1 || fail "'$1' is not installed." "${2:-}"; }

trim_err() { tr -d '\r' | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g; s/^ +| +$//g' | cut -c1-400; }

# fs <cli args...>: run the CLI; on failure, report its (trimmed) stderr and stop.
# Retries only when the connection was never established (nothing was sent), so it's safe for writes too.
fs() {
  local out attempt=1
  while :; do
    if out=$(flagsmith "$@" 2>"$PIW_TMP/err"); then printf '%s' "$out"; return 0; fi
    if (( attempt < 3 )) && grep -qE 'dial tcp|TLS handshake timeout|no such host|connection refused' "$PIW_TMP/err"; then
      sleep $(( attempt * 2 )); attempt=$(( attempt + 1 )); continue
    fi
    fail "flagsmith ${1:-} ${2:-} failed: $(trim_err <"$PIW_TMP/err")"
  done
}

# fsq <jq-expr> <cli args...>: fs with --jq, with surrounding quotes stripped from string results.
# `|| exit 1` matters: bash doesn't apply `set -e` inside $(...), so without it a failed call would
# print its error and then hand an empty value to the caller.
fsq() {
  local expr=$1; shift
  local v
  v=$(fs "$@" --jq "$expr") || exit 1
  v=${v#\"}; v=${v%\"}
  printf '%s' "$v"
}

# api <path> [flags...]: Admin API call with the CLI's credentials (GET unless -X/-F/--input given).
api() { fs api "$@" --json; }
apiq() { local expr=$1; shift; fsq "$expr" api "$@"; }

check_cli() {
  need flagsmith "Install: curl -fsSL https://get.flagsmith.com | sh   (or: brew install Flagsmith/tap/flagsmith)"
  local v; v=$(flagsmith --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 | cut -d. -f1)
  [[ ${v:-0} -ge 2 ]] || fail "Flagsmith CLI v2+ required (found: $(flagsmith --version 2>/dev/null))." "Upgrade: curl -fsSL https://get.flagsmith.com | sh"
}

# Fill ENV_KEY, ENV_NAME, ENV_SOURCE, PROJECT, API_URL, DASHBOARD in one CLI call.
# ENV_SOURCE says where the environment came from (config = flagsmith.json, env = FLAGSMITH_ENVIRONMENT,
# flag = -e), so a stray environment variable can't silently retarget a write.
resolve_context() {
  local cfg
  cfg=$(fs config --jq '"\(.environment.value // "")\t\(.environment.name // "")\t\(.environment.source // "")\t\(.project.value // "")\t\(.apiUrl.value // "")"')
  IFS=$'\t' read -r ENV_KEY ENV_NAME ENV_SOURCE PROJECT API_URL <<<"$cfg"
  [[ -n $ENV_KEY && $ENV_KEY != null ]] || fail "No environment selected." "Run: flagsmith init --project <name> --environment <client-side key>   or set FLAGSMITH_ENVIRONMENT"
  [[ -n $PROJECT && $PROJECT != null ]] || fail "No project selected." "Run: flagsmith init --project <name> --environment <client-side key>   or set FLAGSMITH_PROJECT"
  [[ -n $ENV_NAME ]] || ENV_NAME=$(fsq '.name' environment get "$ENV_KEY")
  case $API_URL in
    https://api.flagsmith.com*) DASHBOARD=https://app.flagsmith.com ;;
    *) DASHBOARD=$(printf '%s' "${API_URL%/}" | sed -E 's#/api(/v1)?$##') ;;
  esac
  DASHBOARD=${PIW_DASHBOARD:-$DASHBOARD}
}

# Environment names that mean "real users".
production_like() { [[ $1 =~ ^([Pp]rod|PROD|[Pp]roduction|PRODUCTION|[Ll]ive|LIVE|[Pp]rd|PRD) ]] && echo true || echo false; }

# guard_env <--confirm-env value>: call before any write.
#  - a confirmed name that differs from the resolved environment always refuses (wrong target);
#  - a production-like environment refuses unless its exact name was confirmed.
# The agent passes --confirm-env only after the human said yes to that environment by name.
guard_env() {
  local want=${1:-}
  if [[ -n $want && $want != "$ENV_NAME" ]]; then
    fail "Refusing: --confirm-env says '$want' but this would change '$ENV_NAME' ($ENV_KEY, from $ENV_SOURCE)." \
      "Check flagsmith.json and FLAGSMITH_ENVIRONMENT, then re-run against the environment you meant."
  fi
  if [[ $(production_like "$ENV_NAME") == true && $want != "$ENV_NAME" ]]; then
    fail "Refusing: '$ENV_NAME' looks like production and was not confirmed." \
      "Ask the human to approve changing '$ENV_NAME'. With their yes, re-run with --confirm-env \"$ENV_NAME\"."
  fi
}

env_json() { printf '{"name":%s,"key":%s,"source":%s}' "$(json_str "$ENV_NAME")" "$(json_str "$ENV_KEY")" "$(json_str "$ENV_SOURCE")"; }

PIW_TMP=$(mktemp -d 2>/dev/null || mktemp -d -t piw)
trap 'rm -rf "$PIW_TMP"' EXIT
STATE_DIR=${PIW_STATE_DIR:-.prove-it-works}
