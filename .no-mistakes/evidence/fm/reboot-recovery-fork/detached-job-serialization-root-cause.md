# Detached restored-worker job: quick worker's line blocked behind the slow worker

Scenario: tests/fm-restored-recover.test.sh "the detached job ... publishes each worker's line
before the sweep finishes" (two gate-parked workers: `quick` fails fast on missing brief,
`slow` ignores TERM so its stop takes ~10s; job bound FM_RESTORED_RECOVER_TIMEOUT=6).

Observed on this host (primary harness detected by bin/fm-harness.sh = `claude`):
- Full test: 2 of 4 runs failed with
  `not ok - the quick worker's line was never published; results:
   RESTORED_WORKER: sweep: stopped by its 6s bound (FM_RESTORED_RECOVER_TIMEOUT); ...`
- Instrumented copy (bound raised to 30s, time from --background return to quick's line):
  0.21s, 0.21s, 14.8s, 0.21s, 0.21s, 18.4s, 14.9s, 18.6s, ... (bimodal)
- Process snapshot during a slow run: quick's `fm-control.sh quick relaunch` sits in a
  `sleep 0.1` loop (fm_lock_acquire_wait, bin/fm-wake-lib.sh:1266) while slow's fm-control
  is stopping its agent.

Root cause: fm-control calls fm_lease_guard (bin/fm-control.sh:327). With no
config/supervision-host-off and a Claude primary, fm_supervision_host_enabled is true by default
(bin/fm-supervision-engine-lib.sh:73-77), so the guard takes the HOME-WIDE
state/.fm-lease-command.lock and keeps it until fm-control's EXIT cleanup (bin/fm-lease-lib.sh:220-225).
Every relaunch the sweep "runs concurrently" therefore serializes behind whichever worker grabbed
the lock first, including that worker's full TERM/KILL wait and launch wait.

Control: same instrumented test with `touch $LAB/home/config/supervision-host-off`:
10/10 runs published quick's line in 0.11-0.22s.

Impact: on the default Claude-primary setup (the captain's), the sweep's relaunches are serial,
not concurrent, contrary to the fm-restored-recover.sh header ("Relaunches run concurrently, and
each worker's line is published the moment that worker is settled"; the 300s default bound is
sized "all relaunches running concurrently"). One slow or stuck worker delays every other
restored worker's recovery, and several slow relaunches can exhaust the 300s bound, leaving
workers reported as "not confirmed recovered".

Side observation: when the job's bound expires, the in-flight `fm-control ... relaunch`
children are not killed (orphans reparented to init kept running for >400s in this run because
their lab home had been deleted and they spun on fm_lock_acquire_wait). They were killed by pid.
