#!/usr/bin/env bash
# Live CLI drive of fm-ticket / fm-backlog-handoff / fm-captain-hold / fm-fleet-snapshot
# across disposable lab homes (main + two local secondmates), run inside a real tmux
# server on the lab's private socket so wakes hit real panes.
set -u
R=$1 LAB=$2
M=$LAB/main A=$LAB/alpha B=$LAB/beta
step() { printf '\n### %s\n' "$*"; }
run() { local h=$1; shift; printf '$ [FM_HOME=%s] %s\n' "${h##*/}" "$*"; FM_HOME=$h "$@"; printf '(exit %s)\n' "$?"; }
T=$R/bin/fm-ticket.sh X=$R/bin/fm-tasks-axi.sh HO=$R/bin/fm-backlog-handoff.sh CH=$R/bin/fm-captain-hold.sh

step "S1 owner lookup: main sees mate-owned ticket; mate sees primary-owned ticket via parent"
FM_HOME=$M $X add m-one "Main ticket" --repo gamma --queue >/dev/null
FM_HOME=$A $X add a-one "Alpha ticket" --repo alpha --queue --body "original body" >/dev/null
FM_HOME=$A $X add a-dep "Alpha dep" --repo alpha --queue >/dev/null
run $M $T owner a-one
run $A $T owner m-one
run $B $T owner a-one
run $M $T owner ghost-key

step "S2 main edits a mate-owned ticket: routed request applied in owner, acked, idempotent replay"
run $M $T edit a-one --request-id hive-req-1 --title "Alpha ticket v2" --priority 1 --note "from hive desk" --block a-dep
run $M $T edit a-one --request-id hive-req-1 --title "Alpha ticket v2" --priority 1 --note "from hive desk" --block a-dep
echo "note count in owner backlog: $(grep -c 'from hive desk' $A/data/backlog.md)"
run $M $T edit a-one --request-id hive-req-1 --title "conflicting content"
run $M $T status hive-req-1
ls $M/state/ticket-requests $A/state/ticket-receipts
FM_HOME=$A $X show a-one --full
echo "main backlog carries a-one? $(grep -c a-one $M/data/backlog.md)"

step "S3 mate edits a primary-owned ticket and a sibling-mate-owned ticket (both directions)"
FM_HOME=$B $X add b-one "Beta ticket" --repo beta --queue >/dev/null
run $A $T edit m-one --request-id alpha-req-1 --note "alpha says hi"
run $A $T edit b-one --request-id alpha-req-2 --priority 0
FM_HOME=$M $X show m-one --full | grep -E 'alpha says hi|title'
FM_HOME=$B $X show b-one | grep -E 'priority'

step "S4 adversarial: invalid edit, closed ticket, absent ticket, unhold of a captain hold"
run $M $T edit a-one --priority 9
FM_HOME=$A $X add a-done "Done one" --repo alpha --queue >/dev/null
FM_HOME=$A $X done a-done >/dev/null 2>&1 || FM_HOME=$A $X close a-done >/dev/null 2>&1
run $M $T edit a-done --note "late"
run $M $T edit ghost-key --note "x"
FM_HOME=$A $CH hold a-cap --title "Captain call in alpha" --reason "need captain choice" --repo alpha >/dev/null
run $M $T edit a-cap --unhold

step "S5 adversarial: owner unreachable -> pending, then resume-pending delivers once"
chmod 000 $A/data/backlog.md
run $M $T edit a-one --request-id hive-req-2 --note "queued while unreadable"
chmod 600 $A/data/backlog.md
run $M $T resume-pending
run $M $T status hive-req-2
echo "note count: $(grep -c 'queued while unreadable' $A/data/backlog.md)"

step "S6 reverse and lateral handoff (queued only)"
FM_HOME=$A $X add a-move "Move me" --repo alpha --queue >/dev/null
FM_HOME=$A $X add a-lat "Lateral" --repo alpha --queue >/dev/null
run $M $HO --from alpha main a-move
run $M $HO --from alpha beta a-lat
run $M $T owner a-move
run $M $T owner a-lat
FM_HOME=$A $X add a-fly "In flight item" --repo alpha >/dev/null
FM_HOME=$A $X start a-fly >/dev/null 2>&1 || true
grep -n 'a-fly' $A/data/backlog.md
run $M $HO --from alpha main a-fly

step "S7 one-step new ticket in project X lands in owning home; rerun converges"
run $M $T new beta "Hive: add the thing" --key hive-new-1 --body "made from hive"
run $M $T new beta "Hive: add the thing" --key hive-new-1 --body "made from hive"
run $M $T owner hive-new-1
run $M $T new gamma "Local project ticket" --key main-new-1
run $M $T owner main-new-1

step "S8 owner-aware keyed answer + reconcile for a call held in a secondmate"
run $M $CH answers --any-origin --source "hive live" <<<"$(printf 'a-cap\tgo with B\tOption B')"
FM_HOME=$A $X show a-cap | grep -E 'state|status'
FM_HOME=$A $CH hold a-cap2 --title "Second call" --reason "pending" --repo alpha >/dev/null
run $M $CH bind hive-src
run $M $CH reconcile-requests --source-id hive-src --source "hive live" <<<"$(printf 'a-cap2\tnote text')"
ls $A/state/reconcile-requests/ ; ls $M/state/reconcile-requests/ 2>&1
run $M $CH reconcile-requests --source-id hive-src --source "hive live" <<<"$(printf 'ghost-call\tx')"

step "S9 rollup names owner per ticket and pages past secondmate bounds"
for i in 1 2 3 4; do FM_HOME=$B $X add b-q$i "Beta queued $i" --repo beta --queue >/dev/null; done
FM_HOME=$M FM_SNAPSHOT_SECONDMATE_QUEUED=2 $R/bin/fm-fleet-snapshot.sh --json > $LAB/snap.json; echo "(snapshot exit $?)"
jq '{main_backlog: [.backlog.records[]? | {id, owner}], mates: [.secondmate_current.records[]? | {id, owner, counts, queued: [.queued[]? | {id, owner}], omitted}]}' $LAB/snap.json
run $M $R/bin/fm-fleet-snapshot.sh --secondmate-page beta --surface queued --offset 0 --limit 10
