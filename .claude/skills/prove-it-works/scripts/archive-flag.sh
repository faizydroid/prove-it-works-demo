#!/usr/bin/env bash
# archive-flag.sh — retire the flag once the code no longer needs it. Archive, never delete:
# the experiment, its results and the audit trail stay readable.
#
#   bash scripts/archive-flag.sh --flag landing_headline --pr 12
#   bash scripts/archive-flag.sh --flag landing_headline --no-pr      # cleanup landed without a PR
#
# Archiving is project-wide: the flag disappears from every environment's dashboard.
# Refuses unless ALL of:
#   - the cleanup PR is MERGED (gh), or --no-pr was passed deliberately
#   - `git grep` finds no reference to the flag in code (docs and *.md are ignored)
#   - no unfinished experiment uses the flag in any environment of the project
#
# Output: {"ok":true,"flag":"landing_headline","archived":true,"pr":12,"pr_state":"MERGED","code_references":0}
. "$(dirname "$0")/_lib.sh"

FLAG= PR= NO_PR=false
while [[ $# -gt 0 ]]; do
  case $1 in
    --flag) FLAG=$2; shift 2 ;;
    --pr) PR=$2; shift 2 ;;
    --no-pr) NO_PR=true; shift ;;
    *) fail "Unknown argument: $1" ;;
  esac
done
[[ -n $FLAG ]] || fail "--flag <name> is required"
[[ -n $PR || $NO_PR == true ]] || fail "Pass --pr <number> (the merged cleanup PR) or --no-pr if the cleanup landed without one."

check_cli
resolve_context
PROJECT_ID=$(fsq '.id' project get "$PROJECT")

# ---- 1. the PR that removed the code is merged ---------------------------------------------------
PR_STATE=none
if [[ -n $PR ]]; then
  need gh "Install GitHub CLI: https://cli.github.com"
  PR_STATE=$(gh pr view "$PR" --json state --jq .state 2>"$PIW_TMP/err") || fail "gh pr view $PR failed: $(trim_err <"$PIW_TMP/err")"
  [[ $PR_STATE == MERGED ]] || fail "Refusing: PR #$PR is $PR_STATE, not MERGED. The flag is still in the code that ships." "Merge the PR first, then re-run."
fi

# ---- 2. no code still reads the flag -----------------------------------------------------------
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  # Skip this skill's own folder when it's installed inside the repo (its examples name flags).
  SKILL_PREFIX=$(cd "$(dirname "$0")/.." && git rev-parse --show-prefix 2>/dev/null || true)
  EXCLUDE_SKILL=()
  [[ -n $SKILL_PREFIX ]] && EXCLUDE_SKILL=(":(top,exclude)${SKILL_PREFIX}**")
  REFS=$(cd "$(git rev-parse --show-toplevel)" && git grep -I -l -e "$FLAG" -- . ':(exclude)*.md' ':(exclude)docs/**' \
    ':(exclude).prove-it-works/**' ':(exclude)**/flagsmith.json' "${EXCLUDE_SKILL[@]+"${EXCLUDE_SKILL[@]}"}" 2>/dev/null || true)
  COUNT=$(printf '%s' "$REFS" | grep -c . || true)
  if [[ ${COUNT:-0} -gt 0 ]]; then
    LIST=$(printf '%s' "$REFS" | head -n 10 | tr '\n' ' ')
    fail "Refusing: '$FLAG' is still referenced in $COUNT file(s): $LIST" "Remove the flag reads (hardcode the winner), merge, then re-run."
  fi
else
  COUNT=-1   # not a git checkout: can't check, say so
fi

# ---- 3. no live experiment on the flag, in ANY environment (archiving is project-wide) ------------
FEATURE_ID=$(fsq '.id' feature get "$FLAG")
LIST='(if type == "array" then . else .results end)[]?'
BUSY=""
for key in $(fs environment list --jq '.[].api_key'); do
  n=$(apiq "[$LIST | select(.feature.id == $FEATURE_ID and .status != \"completed\")] | length" "api/v1/environments/$key/experiments/?page_size=200")
  if [[ ${n:-0} -gt 0 ]]; then BUSY+="${BUSY:+, }$(fsq '.name' environment get "$key") ($n)"; fi
done
[[ -z $BUSY ]] || fail "Refusing: unfinished experiment(s) still use '$FLAG' in: $BUSY. Archiving is project-wide." "Complete them with rollout-winner.sh in each environment first."

# ---- 4. archive and verify ---------------------------------------------------------------------
fs feature update "$FLAG" --archive >/dev/null
ARCHIVED=$(apiq '.is_archived' "api/v1/projects/$PROJECT_ID/features/$FEATURE_ID/")
[[ $ARCHIVED == true ]] || fail "Archive was accepted but the feature does not report is_archived=true."

printf '{"ok":true,"flag":%s,"archived":true,"pr":%s,"pr_state":%s,"code_references":%s}\n' \
  "$(json_str "$FLAG")" "${PR:-null}" "$(json_str "$PR_STATE")" "$COUNT"
