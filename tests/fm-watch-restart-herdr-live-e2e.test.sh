#!/usr/bin/env bash
# Live token-free guard for primary gate findings on a real isolated Herdr pane.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate default-on FM_WATCH_RESTART_HERDR_LIVE claude herdr jq
CLAUDE_VERSION=$(claude --version)
printf 'Live primary gate guard: %s\n' "$CLAUDE_VERSION"
HERDR_LAB_HELPER=${FM_HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name reboot-recovery-watcher)
LAB=$(fm_test_tmproot fm-watch-primary)
cleanup() {
  local rc=$?
  trap - EXIT
  "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || rc=1
  fm_test_cleanup
  [ "$rc" -eq 0 ] || printf 'not ok - primary gate guard failed [%s]\n' "$CLAUDE_VERSION" >&2
  exit "$rc"
}
trap cleanup EXIT
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION"
mkdir -p "$LAB/home/state" "$LAB/bin"
export LAB HERDR_LAB_SESSION HERDR_LAB_HELPER
# Every backend Herdr read also travels through the required helper. Never
# accept a call aimed at another session, even when its pane id looks familiar.
cat > "$LAB/bin/herdr" <<'SH'
#!/usr/bin/env bash
set -eu
args=()
session=
while [ "$#" -gt 0 ]; do
  if [ "$1" = --session ]; then session=$2; shift 2; else args+=("$1"); shift; fi
done
[ "$session" = "$HERDR_LAB_SESSION" ] || exit 91
# Keep the helper's own calls on the real CLI, not this shim.
PATH=${PATH#"$LAB/bin:"} exec "$HERDR_LAB_HELPER" run "$session" "${args[@]}"
SH
chmod +x "$LAB/bin/herdr"
created=$("$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" workspace create --cwd "$LAB/home" --label restart-primary --no-focus)
printf '%s\n' "$created"
pane=$(printf '%s' "$created" | jq -r '.result.root_pane.pane_id // empty')
[ -n "$pane" ]
start_out=$("$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" agent start restart-primary --kind claude --pane "$pane" 2>&1) || {
  printf '%s\n' "$start_out"
  printf '%s' "$start_out" | grep -q agent_not_ready || exit 1
}
for i in $(seq 1 100); do
  screen=$("$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane read "$pane" --format text 2>/dev/null) || screen=
  if printf '%s' "$screen" | grep -Eq 'Accessing workspace:|Allow external CLAUDE.md file imports\?|Teach auto mode about your environment\?'; then break; fi
  sleep 0.2
done
printf '%s\n' "$screen"
PID_BEFORE=$(PATH="$LAB/bin:$PATH" bash -c '. "$1/bin/fm-backend.sh"; fm_backend_agent_pids herdr "$2"' _ "$ROOT" "$HERDR_LAB_SESSION:$pane")
[ -n "$PID_BEFORE" ]
PATH="$LAB/bin:$PATH" FM_HOME="$LAB/home" FM_SUPERVISOR_BACKEND=herdr \
 FM_SUPERVISOR_TARGET="$HERDR_LAB_SESSION:$pane" FM_RESTORED_RECOVER_SETTLE=2 \
 "$ROOT/bin/fm-restored-recover.sh" --background
for i in $(seq 1 100); do
  if grep -q 'RESTORED_WORKER: primary: parked on' "$LAB/home/state/".restored-recover.results.* 2>/dev/null; then break; fi
  sleep 0.2
done
cat "$LAB/home/state/".restored-recover.results.*
grep -q 'RESTORED_WORKER: primary: parked on' "$LAB/home/state/".restored-recover.results.*
grep -q 'check: restored-workers' "$LAB/home/state/.wake-queue"
"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane process-info --pane "$pane"
kill -0 "$PID_BEFORE"
pass 'real primary gate produces detached durable finding and wake; session preserved without input or new consent'
