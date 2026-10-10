#!/usr/bin/env bash
# Live scenario (test-phase evidence): a session start in a marked lab home
# launches the detached restored-worker sweep, which relaunches a real Claude
# worker parked on a startup gate and publishes results + a wake for the worker
# it could not relaunch. tmux backend on the lab's private socket.
# Usage: round2-session-start-trigger.sh <repo-root> <evidence-dir>
set -u
REPO=$1 EVID=$2
. "$REPO/tests/lib.sh"
for var in $(env | sed -n 's/^\(CLAUDE[A-Z0-9_]*\)=.*/\1/p'); do
  [ "$var" = CLAUDE_CONFIG_DIR ] || unset "$var"
done
unset TMUX TMUX_PANE NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE \
  FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE HERDR_ENV HERDR_PANE_ID HERDR_SESSION \
  HERDR_SOCKET_PATH HERDR_TAB_ID HERDR_WORKSPACE_ID
fail() { printf 'FAIL - %s\n' "$1"; exit 1; }
log() { printf '== %s\n' "$1"; }

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); LAB=$(cd "$LAB" && pwd -P)
"$REPO/bin/fm-lab-home.sh" create "$LAB" >/dev/null || fail "lab create"
export TMUX_TMPDIR; TMUX_TMPDIR=$("$REPO/bin/fm-lab-home.sh" tmux-dir "$LAB") || fail tmuxdir
export FM_HOME="$LAB"
export FM_GATE_REFUSE_BYPASS=1  # disposable lab home only; see testing summary
cleanup() {
  trap - EXIT
  tmux kill-server >/dev/null 2>&1
  "$REPO/bin/fm-lab-home.sh" teardown "$LAB" >/dev/null 2>&1
  chmod -R u+w "$LAB" 2>/dev/null; rm -rf "$LAB"
}
trap cleanup EXIT
tmux new-session -d -s firstmate -x 200 -y 50 -c "$LAB" -- /bin/sh || fail "tmux server"

mk_worker() {  # <id> <with-brief:1|0>
  local id=$1 wt="$LAB/w-$1"
  fm_git_worktree "$LAB/p-$id" "$wt" "task-$id" >/dev/null 2>&1 || fail "worktree $id"
  mkdir -p "$LAB/data/$id"
  [ "$2" = 1 ] && printf '# Task\n## Captain'"'"'s intent\nReply with the single word READY and stop. Do not run tools.\n\n## Firstmate spec\nReply READY only.\n' > "$LAB/data/$id/brief.md"
  fm_write_meta "$LAB/state/$id.meta" "window=firstmate:fm-$id" "endpoint_task_id=$id" \
    "worktree=$wt" "project=$LAB/p-$id" harness=claude kind=ship mode=no-mistakes yolo=off \
    model=default effort=default backend=tmux "tasktmp=$LAB/tmp-$id"
  # untrusted worktree -> real Claude parks on its folder-trust gate
  tmux new-window -d -t firstmate: -n "fm-$id" -c "$wt" -- /bin/sh -c 'claude; exec /bin/sh' || fail "window $id"
}
mk_worker gated 1
mk_worker nobrief 0
. "$REPO/bin/fm-backend.sh"; . "$REPO/bin/fm-composer-lib.sh"
for id in gated nobrief; do
  i=0; g=
  while [ $i -lt 120 ]; do
    s=$(fm_backend_visible_capture tmux "firstmate:fm-$id" 2>/dev/null)
    g=$(fm_composer_startup_dialog "$s") && break; i=$((i+1)); sleep 0.5
  done
  echo "$id: gate on screen: ${g:-NONE}; agent state: $(fm_backend_agent_state tmux "firstmate:fm-$id")"
  printf '%s\n' "$s" > "$EVID/round2-session-start-$id-before.txt"
done

log "run bin/fm-session-start.sh in the lab home"
START=$(date +%s)
"$REPO/bin/fm-session-start.sh" > "$EVID/round3-session-start-digest.txt" 2>&1; echo "session-start rc=$? in $(( $(date +%s) - START ))s"
grep -n "RESTORED_WORKER\|restored-worker\|READ-ONLY" "$EVID/round3-session-start-digest.txt" | head
sleep 2
log "wait for the detached job's results"
i=0
while [ $i -lt 150 ]; do
  R=$(ls "$LAB/state"/.restored-recover.results.* 2>/dev/null | head -1)
  [ -n "$R" ] && [ "$(wc -l < "$R")" -ge 2 ] && break
  i=$((i+1)); sleep 1
done
echo "results file: ${R:-none}"; [ -n "${R:-}" ] && cat "$R"
sleep 10
log "after"
for id in gated nobrief; do
  s=$(fm_backend_visible_capture tmux "firstmate:fm-$id" 2>/dev/null)
  printf '%s\n' "$s" > "$EVID/round2-session-start-$id-after.txt"
  p=$(fm_backend_agent_pids tmux "firstmate:fm-$id" 2>/dev/null | head -1)
  echo "$id: agent=$(fm_backend_agent_state tmux "firstmate:fm-$id") gate=$(fm_composer_startup_dialog "$s" || echo none) pid=$p cwd=$(readlink /proc/$p/cwd 2>/dev/null)"
done
log "wakes mentioning restored-workers"
grep -rl "restored-workers" "$LAB/state" 2>/dev/null | grep -v results | while read -r f; do echo "$f:"; grep -h "restored-workers" "$f" | head -3; done
