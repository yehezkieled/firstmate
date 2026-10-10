#!/usr/bin/env bash
# Live scenario (test-phase evidence, not a repo test): reproduce the reported
# post-reboot state on a REAL Herdr lab session with the REAL Claude Code:
# a ship worker's Herdr pane runs `claude` in the project's PRIMARY checkout
# (not its worktree), parked on "Allow external CLAUDE.md file imports?".
# Then run bin/fm-restored-recover.sh (the sweep session start launches) and
# check that the worker is relaunched in its recorded worktree without the
# imports dialog ever being approved.
# Usage: round2-herdr-real-claude-restart.sh <repo-root> <evidence-dir>
set -u
REPO=$1 EVID=$2
# shellcheck source=/dev/null
. "$REPO/tests/lib.sh"
. "$REPO/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane
for var in $(env | sed -n 's/^\(CLAUDE[A-Z0-9_]*\)=.*/\1/p'); do
  [ "$var" = CLAUDE_CONFIG_DIR ] || unset "$var"
done
STORE="${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json"

fail() { printf 'FAIL - %s\n' "$1"; exit 1; }
log() { printf '== %s\n' "$1"; }

SESSION="fm-lab-rr-claude-$$"
export HERDR_SESSION="$SESSION"
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-rr-claude.XXXXXX"); SCRATCH=$(cd "$SCRATCH" && pwd -P)
cleanup() {
  trap - EXIT
  herdr_safe_stop_and_delete "$SESSION" || echo "WARN: teardown of $SESSION failed"
  rm -rf "$SCRATCH"
  fm_test_cleanup
}
trap cleanup EXIT
fm_herdr_lab_prepare "$SESSION" || fail "lab prepare"

HOME_DIR="$SCRATCH/home" ID=rrship PROJ="$SCRATCH/proj" WT="$SCRATCH/wt"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data/$ID"
printf '# Task\n## Captain'"'"'s intent\nReply with the single word READY and stop. Do not run tools.\n\n## Firstmate spec\nReply READY only.\n' \
  > "$HOME_DIR/data/$ID/brief.md"
fm_git_worktree "$SCRATCH/base" "$WT" "task-$ID" || fail "worktree"
# The "primary checkout" the restored pane lands in is a sibling checkout of the
# same repo; it is made a git worktree only so bin/fm-claude-trust.sh will trust
# it (it refuses primary checkouts), matching a primary the captain already trusts.
git -C "$SCRATCH/base" worktree add --quiet -b primary-co "$PROJ" || fail "proj checkout"
# Primary checkout (uncommitted, so absent from the worktree) imports a file
# outside the project, like the aer-tariff-recon primary checkout did.
printf 'outside notes\n' > "$SCRATCH/outside.md"
printf '# Proj\n@../outside.md\n' > "$PROJ/CLAUDE.md"
"$REPO/bin/fm-claude-trust.sh" "$PROJ" "$PROJ" >/dev/null || fail "trust primary checkout"

. "$REPO/bin/fm-backend.sh"
fm_backend_source herdr || fail "backend"
. "$REPO/bin/fm-composer-lib.sh"
RAW=$(fm_backend_herdr_container_ensure "$WT") || fail container
CONTAINER=${RAW%%$'\t'*}; SEEDED=${RAW#*$'\t'}; WS=${CONTAINER#*:}
read -r TAB PANE <<IDS
$(fm_backend_herdr_create_task "$CONTAINER" "fm-$ID" "$WT" "$SEEDED")
IDS
TARGET="$SESSION:$PANE"
fm_write_meta "$HOME_DIR/state/$ID.meta" \
  "window=$TARGET" "endpoint_task_id=$ID" "worktree=$WT" "project=$PROJ" \
  harness=claude kind=ship mode=no-mistakes yolo=off "tasktmp=$SCRATCH/tmp" \
  model=default effort=default backend=herdr "herdr_session=$SESSION" \
  "herdr_workspace_id=$WS" "herdr_tab_id=$TAB" "herdr_pane_id=$PANE"

log "restored state: pane top shell in primary checkout, running claude there"
printf -v PQ '%q' "$PROJ"
fm_backend_herdr_send_text_line "$TARGET" "cd -- $PQ && claude" || fail "start claude"
i=0; gate=
while [ $i -lt 120 ]; do
  screen=$(fm_backend_visible_capture herdr "$TARGET" 2>/dev/null) || screen=
  gate=$(fm_composer_startup_dialog "$screen") && break
  i=$((i+1)); sleep 0.5
done
[ -n "$gate" ] || fail "claude never showed a startup gate; viewport:
$screen"
printf '%s\n' "$screen" > "$EVID/round2-herdr-claude-before.txt"
OLD_PID=$(fm_backend_agent_pids herdr "$TARGET" 2>/dev/null | head -1)
echo "gate on screen: $gate"
echo "agent state: $(fm_backend_agent_state herdr "$TARGET")"
echo "old claude pid=$OLD_PID cwd=$(readlink /proc/$OLD_PID/cwd 2>/dev/null)"
echo "recorded worktree=$WT"

log "run the restored-worker sweep (foreground)"
START=$(date +%s)
OUT=$(env FM_HOME="$HOME_DIR" "$REPO/bin/fm-restored-recover.sh" 2>&1); RC=$?
echo "sweep rc=$RC after $(( $(date +%s) - START ))s"
printf '%s\n' "$OUT"

log "after: wait for replacement claude"
i=0; NEW_PID=
while [ $i -lt 60 ]; do
  NEW_PID=$(fm_backend_agent_pids herdr "$TARGET" 2>/dev/null | head -1)
  [ -n "$NEW_PID" ] && [ "$NEW_PID" != "$OLD_PID" ] && break
  i=$((i+1)); sleep 0.5
done
sleep 8
screen=$(fm_backend_visible_capture herdr "$TARGET" 2>/dev/null)
printf '%s\n' "$screen" > "$EVID/round2-herdr-claude-after.txt"
echo "old pid alive: $(kill -0 "$OLD_PID" 2>/dev/null && echo yes || echo no)"
echo "new claude pid=$NEW_PID cwd=$(readlink /proc/$NEW_PID/cwd 2>/dev/null)"
echo "agent state: $(fm_backend_agent_state herdr "$TARGET")"
echo "gate on screen now: $(fm_composer_startup_dialog "$screen" || echo none)"
echo "imports approved for primary checkout: $(jq -r --arg p "$PROJ" '.projects[$p].hasClaudeMdExternalIncludesApproved // "unset"' "$STORE")"
echo "control-relaunch marker: $(ls "$HOME_DIR/state" | grep -c control-relaunch)"
log "second sweep on the now-healthy worker (expect no output)"
OUT2=$(env FM_HOME="$HOME_DIR" "$REPO/bin/fm-restored-recover.sh" 2>&1); echo "rc=$? output=[$OUT2]"
# stop the replacement claude before teardown
kill "$NEW_PID" 2>/dev/null
# forget lab paths in the user's claude store is not done: entries are inert.
