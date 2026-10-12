#!/usr/bin/env bash
# Portable watcher boot-trigger regression, including rearming and launch failure.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
LAB=$(fm_test_tmproot fm-watch-restart)
trap fm_test_cleanup EXIT
mkdir -p "$LAB/home/state" "$LAB/bin"
export FM_HOME="$LAB/home" FM_STATE_OVERRIDE="$LAB/home/state"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-watch.sh"
SCRIPT_DIR="$LAB/bin"
cat > "$SCRIPT_DIR/fm-restored-recover.sh" <<'SH'
#!/usr/bin/env bash
[ "$1" = --background ] || exit 2
[ ! -e "$FM_HOME/fail" ] || exit 1
printf '%s\n' "$FM_HOME" >> "$FM_HOME/launches"
SH
chmod +x "$SCRIPT_DIR/fm-restored-recover.sh"
# Control only the OS identity; exercise production launch and publication.
# shellcheck disable=SC2329 # Called by sourced watcher_restart_recovery.
watcher_boot_identity() { printf '%s' "$BOOT"; }
BOOT=aaaa-bbbb
watcher_restart_recovery || fail "first observation failed"
watcher_restart_recovery || fail "same boot failed"
[ "$(wc -l < "$FM_HOME/launches" | tr -d ' ')" = 1 ] || fail "same boot launched twice"
# A new watcher process must honor the durable marker, rather than its memory.
export SCRIPT_DIR STATE BOOT
export -f watcher_boot_identity watcher_restart_recovery
bash -c watcher_restart_recovery || fail "rearm failed"
[ "$(wc -l < "$FM_HOME/launches" | tr -d ' ')" = 1 ] || fail "rearm launched again"
BOOT=cccc-dddd
watcher_restart_recovery || fail "new boot failed"
[ "$(wc -l < "$FM_HOME/launches" | tr -d ' ')" = 2 ] || fail "new boot was skipped"
BOOT=eeee-ffff
touch "$FM_HOME/fail"
if watcher_restart_recovery 2> "$LAB/error"; then fail "failed launch marked recovered"; fi
[ "$(cat "$STATE/.watch-restored-boot")" = cccc-dddd ] || fail "failed boot consumed"
grep -q 'restart remains pending' "$LAB/error" || fail "failure was silent"
rm "$FM_HOME/fail"
watcher_restart_recovery || fail "retry failed"
[ "$(wc -l < "$FM_HOME/launches" | tr -d ' ')" = 3 ] || fail "retry did not launch"
pass "first observation and each boot recover once across cycles and rearming; failed launches retry"
# Missing OS identity must never masquerade as a new boot.
# shellcheck disable=SC2329 # Called by sourced watcher_restart_recovery.
watcher_boot_identity() { return 1; }
if watcher_restart_recovery 2> "$LAB/error"; then fail "missing identity accepted"; fi
[ "$(wc -l < "$FM_HOME/launches" | tr -d ' ')" = 3 ] || fail "identity failure launched recovery"
pass "unreadable boot identity refuses recovery visibly"
# Platform reader: Linux uses the kernel UUID; macOS consumes its UUID without
# a timestamp (which could be changed by a wall-clock correction).
REAL_BOOT=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null) || REAL_BOOT=
if [ -n "$REAL_BOOT" ]; then
  GOT=$(SCRIPT_DIR="$ROOT/bin" bash -c '. "$1"; watcher_boot_identity' _ "$ROOT/bin/fm-watch.sh")
  [ "$GOT" = "$REAL_BOOT" ] || fail "Linux boot identity differs from kernel"
fi
mkdir -p "$LAB/osbin"
cat > "$LAB/osbin/uname" <<'SH'
#!/bin/sh
printf '%s\n' Darwin
SH
cat > "$LAB/osbin/sysctl" <<'SH'
#!/bin/sh
[ "$*" = '-n kern.bootsessionuuid' ] || exit 1
printf '%s\n' ABCDEF12-1234-1234-1234-ABCDEF123456
SH
chmod +x "$LAB/osbin/"*
GOT=$(PATH="$LAB/osbin:$PATH" bash -c '. "$1"; watcher_boot_identity' _ "$ROOT/bin/fm-watch.sh")
[ "$GOT" = ABCDEF12-1234-1234-1234-ABCDEF123456 ] || fail "macOS boot identity was not consumed"
pass "Linux and macOS readers consume kernel boot UUIDs"
# Execute the real watcher with an already queued actionable wake. Recovery
# must be triggered before that wake exits the cycle, without a primary turn.
fm_wake_append check restart-test 'check: restart-test' || fail "could not queue test wake"
if ! bash "$ROOT/bin/fm-watch.sh" > "$LAB/watcher.out" 2> "$LAB/watcher.err"; then
  cat "$LAB/watcher.err" >&2
  fail "watcher failed before delivering queued wake"
fi
GOT=$(cat "$STATE/.watch-restored-boot")
[ "$GOT" != eeee-ffff ] || fail "queued wake skipped restart recovery"
grep -q '^check:' "$LAB/watcher.out" || fail "watcher did not deliver queued wake"
pass "actual watcher triggers recovery before a queued wake exits the cycle"
