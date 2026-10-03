#!/usr/bin/env bash
# tests/fm-ticket.test.sh - ticket ownership lookup, routed edits, and one-step new tickets
# across throwaway primary and secondmate homes (bin/fm-ticket.sh).
set -u

# shellcheck source=tests/secondmate-helpers.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/secondmate-helpers.sh"

command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found (required by the ticket edit path)"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-ticket)
FAKEBIN=$(make_fake_tmux "$TMP_ROOT/fake")
export PATH="$FAKEBIN:$PATH"
export FM_FAKE_TMUX_WINDOW='firstmate:fm-alpha
firstmate:fm-beta'
export FM_FAKE_TMUX_LOG="$TMP_ROOT/tmux.log"
export FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/fake/pane.txt"
export FM_SEND_SETTLE=0 FM_SEND_SLEEP=0 FM_SEND_RETRIES=1

TICKET="$ROOT/bin/fm-ticket.sh"

# A primary home with two registered local mates: alpha lists project alpha, beta lists beta.
setup_fleet() { # <name>; sets H (primary), A, B
  local n=$1 id abs
  H="$TMP_ROOT/$n-main" A="$TMP_ROOT/$n-a" B="$TMP_ROOT/$n-b"
  mkdir -p "$H/data" "$H/state"
  seed_secondmate_home_marker "$A" alpha
  seed_secondmate_home_marker "$B" beta
  A=$(cd "$A" && pwd -P)
  B=$(cd "$B" && pwd -P)
  {
    printf -- '- alpha - alpha work (home: %s; scope: alpha work; projects: alpha; added 2026-07-09)\n' "$A"
    printf -- '- beta - beta work (home: %s; scope: beta work; projects: beta, shared; added 2026-07-09)\n' "$B"
  } > "$H/data/secondmates.md"
  for id in alpha beta; do
    abs=$A
    [ "$id" = alpha ] || abs=$B
    mkdir -p "$abs/state"
    printf 'window=firstmate:fm-%s\nkind=secondmate\nharness=claude\nbackend=tmux\nhome=%s\nworktree=%s\n' \
      "$id" "$abs" "$abs" > "$H/state/$id.meta"
    printf '## In flight\n\n## Queued\n\n## Done\n' > "$abs/data/backlog.md"
    printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$H" > "$abs/.fm-secondmate-parent"
  done
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$H/data/backlog.md"
}

t() { # <home> args...: run fm-ticket in <home>
  local home=$1
  shift
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$TICKET" "$@"
}

axi() { # <home> args...: tasks-axi in <home>'s backlog
  local home=$1
  shift
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-tasks-axi.sh" "$@"
}

test_owner_lookup_names_main_mate_and_absent() {
  setup_fleet own
  axi "$H" add m-one "main ticket" --repo gamma --queue >/dev/null
  axi "$A" add a-one "alpha ticket" --repo alpha --queue >/dev/null
  local out rc=0
  out=$(t "$H" owner m-one) || fail "owner of a main ticket failed: $out"
  assert_contains "$out" "owner=main" "main ticket owner not reported"
  out=$(t "$H" owner a-one) || fail "owner of a mate ticket failed: $out"
  assert_contains "$out" "owner=alpha" "mate ticket owner not reported"
  out=$(t "$H" owner a-one --json) || fail "owner --json failed"
  [ "$(printf '%s' "$out" | jq -r .owner)" = alpha ] || fail "json owner wrong: $out"
  out=$(t "$A" owner m-one) || fail "mate could not see a primary-owned ticket through its parent: $out"
  assert_contains "$out" "owner=main" "mate lookup did not reach the parent"
  out=$(t "$A" owner a-one) || fail "mate could not see its own ticket: $out"
  assert_contains "$out" "owner=alpha" "a mate's own ticket was reported under another home's label"
  rc=0
  out=$(t "$H" owner nothing-here) || rc=$?
  [ "$rc" -eq 1 ] || fail "absent ticket did not exit 1 (got $rc)"
  assert_contains "$out" "owner=none" "absent ticket not reported as none"
  axi "$B" add a-one "dup" --repo beta --queue >/dev/null
  rc=0
  out=$(t "$H" owner a-one) || rc=$?
  [ "$rc" -eq 2 ] || fail "duplicate key did not exit 2 (got $rc)"
  assert_contains "$out" "owner=ambiguous" "duplicate key not reported as ambiguous"
  pass "owner lookup reports main, a mate, absent, parent fallback and ambiguity"
}

test_edit_routes_to_a_mate_applies_acks_and_replays() {
  setup_fleet edit
  axi "$A" add a-one "alpha ticket" --repo alpha --queue --body "first line" >/dev/null
  axi "$A" add a-dep "dependency" --repo alpha --queue >/dev/null
  local out rc=0 shown
  out=$(t "$H" edit a-one --request-id req-1 --title "alpha ticket v2" --priority 1 --note "please prefer X" --block a-dep) \
    || fail "routed edit failed: $out"
  assert_contains "$out" "status=applied" "edit was not acknowledged as applied"
  assert_contains "$out" "owner=alpha" "ack did not name the owner"
  shown=$(axi "$A" show a-one --full)
  assert_contains "$shown" "alpha ticket v2" "title edit did not land in the owner backlog"
  assert_contains "$shown" "priority: 1" "priority edit did not land"
  assert_contains "$shown" "please prefer X" "note was not appended"
  assert_contains "$shown" "first line" "note append lost the original body"
  assert_contains "$shown" "a-dep" "block edit did not land"
  ! grep -q 'a-one' "$H/data/backlog.md" || fail "edit leaked the ticket into the requester backlog"
  [ -f "$A/state/ticket-receipts/req-1.receipt" ] || fail "owner did not record a receipt"
  [ -f "$H/state/ticket-requests/req-1.req" ] || fail "requester did not journal the request"

  out=$(t "$H" edit a-one --request-id req-1 --title "alpha ticket v2" --priority 1 --note "please prefer X" --block a-dep) \
    || fail "replay failed: $out"
  [ "$(axi "$A" show a-one --full | grep -c 'please prefer X')" -eq 1 ] || fail "replay applied the note twice"

  rc=0
  out=$(t "$H" edit a-one --request-id req-1 --title "different") || rc=$?
  [ "$rc" -ne 0 ] || fail "id reuse with different content was accepted"
  out=$(t "$H" status req-1) || fail "status failed"
  assert_contains "$out" "status=" "status did not print a record"
  pass "a routed edit lands in the owning mate, is acknowledged, and replays idempotently"
}

test_edit_rejects_invalid_and_closed_without_partial_effect() {
  setup_fleet rej
  axi "$A" add a-one "alpha ticket" --repo alpha --queue >/dev/null
  local before out rc=0
  before=$(cat "$A/data/backlog.md")
  out=$(t "$H" edit a-one --request-id bad-1 --title "new title" --priority 9) || rc=$?
  [ "$rc" -eq 2 ] || fail "invalid priority exit was $rc, expected 2: $out"
  assert_contains "$out" "status=rejected" "invalid edit not reported rejected"
  [ "$before" = "$(cat "$A/data/backlog.md")" ] || fail "a rejected request partially applied"
  rc=0
  out=$(t "$H" edit a-one --request-id bad-2 --block ghost-dep) || rc=$?
  [ "$rc" -eq 2 ] || fail "cross-home blocker was accepted"
  rc=0
  out=$(t "$H" edit a-one --request-id bad-3 --hold "need a call" --unhold) || rc=$?
  cat > "$A/data/backlog.md" <<'EOT'
## Queued

## Done
- [x] a-done - finished (repo: alpha) (closed 2026-07-01)
EOT
  rc=0
  out=$(t "$H" edit a-done --request-id bad-4 --title "reopen") || rc=$?
  [ "$rc" -eq 2 ] || fail "edit of a closed ticket was accepted: $out"
  assert_contains "$out" "closed" "closed ticket refusal not explained"
  pass "invalid, cross-home-dependency and closed-ticket edits are rejected untouched"
}

test_edit_of_a_moved_ticket_reports_the_new_owner_and_retry_follows() {
  setup_fleet mov
  axi "$A" add a-one "alpha ticket" --repo alpha --queue >/dev/null
  local out rc=0
  # Make the believed owner stale: alpha hands the ticket to beta between lookup and apply.
  FM_HOME="$H" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-backlog-handoff.sh" --from alpha beta a-one >/dev/null 2>&1 \
    || fail "setup lateral handoff failed"
  out=$(t "$H" edit a-one --request-id mv-1 --priority 3) || rc=$?
  [ "$rc" -eq 0 ] || fail "edit after a handoff did not follow the ticket: $out"
  assert_contains "$out" "owner=beta" "edit did not land at the new owner"
  assert_contains "$(axi "$B" show a-one --full)" "priority: 3" "edit did not reach the new owner"
  # A request applied directly at the old owner reports absence, never a silent write.
  printf 'schema=fm-ticket-edit.v1\nrequest=stale-1\nkey=a-one\nop=priority\t2\n' > "$TMP_ROOT/stale.payload"
  rc=0
  out=$(FM_HOME="$A" FM_ROOT_OVERRIDE="$ROOT" "$TICKET" apply --requester main < "$TMP_ROOT/stale.payload") || rc=$?
  [ "$rc" -eq 3 ] || fail "apply at a former owner did not exit 3 (got $rc): $out"
  assert_contains "$out" "status=absent" "former owner did not report the ticket absent"
  pass "an edit follows a moved ticket and the former owner refuses to write"
}

test_mate_requester_edits_primary_and_sibling_tickets_through_its_parent() {
  setup_fleet lat
  axi "$H" add m-one "main ticket" --repo gamma --queue >/dev/null
  axi "$B" add b-one "beta ticket" --repo beta --queue >/dev/null
  local out
  out=$(t "$A" edit m-one --request-id lat-1 --priority 2) || fail "mate to main edit failed: $out"
  assert_contains "$out" "status=applied" "mate to main edit not acknowledged"
  assert_contains "$(axi "$H" show m-one --full)" "priority: 2" "mate edit did not land in main"
  out=$(t "$A" edit b-one --request-id lat-2 --title "beta v2") || fail "mate to mate edit failed: $out"
  assert_contains "$out" "owner=beta" "lateral edit did not name the owning sibling"
  assert_contains "$(axi "$B" show b-one --full)" "beta v2" "lateral edit did not land in the sibling"
  [ -f "$A/state/ticket-requests/lat-2.req" ] || fail "mate did not journal its own request"
  pass "a mate edits primary-owned and sibling-owned tickets through its parent"
}

test_edit_with_an_unreadable_owner_is_pending_and_retry_converges() {
  setup_fleet pend
  axi "$A" add a-one "alpha ticket" --repo alpha --queue >/dev/null
  # A remote mate whose transport is down: nothing may be lost or guessed.
  printf -- '- rem - remote (host: nohost.invalid; root: /nonexistent; home: /nonexistent/home; scope: s; projects: remproj; added 2026-07-09)\n' \
    >> "$H/data/secondmates.md"
  local out rc=0
  out=$(t "$H" edit nowhere-ticket --request-id pend-1 --priority 1) || rc=$?
  [ "$rc" -eq 4 ] || fail "unreadable remote did not leave the request pending (got $rc): $out"
  assert_contains "$out" "status=pending" "pending state not reported"
  [ -f "$H/state/ticket-requests/pend-1.req" ] || fail "pending request was not journaled"
  # The transport comes back as the ticket appears in a readable mate.
  printf -- '- alpha - alpha work (home: %s; scope: alpha work; projects: alpha; added 2026-07-09)\n' "$A" > "$H/data/secondmates.md"
  axi "$A" add nowhere-ticket "late" --repo alpha --queue >/dev/null
  out=$(t "$H" retry pend-1) || fail "retry did not converge: $out"
  assert_contains "$out" "status=applied" "retry was not acknowledged"
  assert_contains "$(axi "$A" show nowhere-ticket --full)" "priority: 1" "retried edit did not land"
  pass "an unreadable owner leaves a journaled pending request that retry delivers"
}

test_mate_without_a_local_parent_route_leaves_an_edit_pending() {
  setup_fleet nopar
  axi "$H" add m-one "main ticket" --repo gamma --queue >/dev/null
  local out rc=0
  mv "$A/.fm-secondmate-parent" "$TMP_ROOT/nopar.parent"
  out=$(t "$A" edit m-one --request-id np-1 --priority 2) || rc=$?
  [ "$rc" -eq 4 ] || fail "an edit a mate cannot route was not left pending (got $rc): $out"
  assert_contains "$out" "status=pending" "an unroutable edit was reported as a definitive outcome"
  out=$(t "$A" owner m-one) || true
  assert_contains "$out" "unreadable=parent" "owner lookup hid that the parent could not be asked"
  mv "$TMP_ROOT/nopar.parent" "$A/.fm-secondmate-parent"
  t "$A" resume-pending >/dev/null || fail "resume-pending did not converge"
  assert_contains "$(t "$A" status np-1)" "status=applied" "resume-pending did not retry the pending edit"
  assert_contains "$(axi "$H" show m-one --full)" "priority: 2" "retried edit did not land"
  printf 'schema=fm-secondmate-parent.v1\nroute=remote\nparent_host=nohost.invalid\n' > "$A/.fm-secondmate-parent"
  rc=0
  out=$(t "$A" edit m-one --request-id np-2 --priority 3) || rc=$?
  [ "$rc" -eq 2 ] || fail "an edit behind a remote parent route was not rejected as unsupported (got $rc): $out"
  assert_contains "$out" "unsupported" "an unroutable edit did not say it is unsupported"
  t "$A" resume-pending >/dev/null || fail "resume-pending retried an unsupported edit"
  pass "a mate with no local parent route keeps the edit pending and resume-pending delivers it; a remote parent route is unsupported"
}

test_replay_after_a_handoff_is_not_applied_twice() {
  setup_fleet rep
  axi "$A" add a-one "alpha ticket" --repo alpha --queue --body "first line" >/dev/null
  local out
  printf 'schema=fm-ticket-edit.v1\nrequest=lost-ack\nkey=a-one\nop=note\t%s\n' "$(printf 'once only' | base64)" \
    > "$TMP_ROOT/lost.payload"
  FM_HOME="$A" FM_ROOT_OVERRIDE="$ROOT" "$TICKET" apply --requester main < "$TMP_ROOT/lost.payload" >/dev/null \
    || fail "direct apply at the owner failed"
  FM_HOME="$H" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-backlog-handoff.sh" --from alpha beta a-one >/dev/null 2>&1 \
    || fail "setup lateral handoff failed"
  out=$(t "$H" edit a-one --request-id lost-ack --note "once only") || fail "replay at the new owner failed: $out"
  assert_contains "$out" "status=replay" "the new owner did not recognize the applied request"
  [ "$(axi "$B" show a-one --full | grep -o 'once only' | wc -l)" -eq 1 ] || fail "the note was applied twice after a handoff"
  out=$(t "$H" edit a-one --request-id rep-2 --body "replaced body") || fail "body replace failed: $out"
  out=$(FM_HOME="$B" FM_ROOT_OVERRIDE="$ROOT" "$TICKET" apply --requester main < "$TMP_ROOT/lost.payload") \
    || fail "replay after a body replace failed: $out"
  assert_contains "$out" "status=replay" "a body replace dropped the applied-request record"
  pass "the applied request id travels in the ticket, so a replay after a handoff is not applied twice"
}

test_new_ticket_lands_in_the_owning_home() {
  setup_fleet new
  local out
  out=$(t "$H" new alpha "Fix the flaky thing" --body "details here" --priority 2) || fail "new for a mate project failed: $out"
  assert_contains "$out" "owner=alpha" "new ticket was not routed to the project's mate"
  assert_grep 'alpha-fix-the-flaky-thing' "$A/data/backlog.md" "ticket did not land in the mate backlog"
  assert_grep 'details here' "$A/data/backlog.md" "ticket body did not travel"
  ! grep -q 'alpha-fix-the-flaky-thing' "$H/data/backlog.md" || fail "ticket stayed in main after handoff"
  out=$(t "$H" new alpha "Fix the flaky thing") || fail "rerun failed: $out"
  assert_contains "$out" "status=exists" "rerun did not converge"
  [ "$(grep -c 'alpha-fix-the-flaky-thing' "$A/data/backlog.md")" -eq 1 ] || fail "rerun duplicated the ticket"
  out=$(t "$H" new gamma "Unowned work") || fail "new for an unlisted project failed: $out"
  assert_contains "$out" "owner=main" "unlisted project did not stay in main"
  assert_grep 'gamma-unowned-work' "$H/data/backlog.md" "ticket missing from main"
  t "$H" new gamma "Fix: login" >/dev/null || fail "new with a quoted title failed"
  out=$(t "$H" new gamma "Fix: login") || fail "rerun with a quoted title did not converge: $out"
  assert_contains "$out" "status=exists" "rerun with a quoted title was not reported as existing"
  t "$H" new alpha "Fix: alpha login" >/dev/null || fail "new for a mate with a quoted title failed"
  out=$(t "$H" new alpha "Fix: alpha login") || fail "mate rerun with a quoted title did not converge: $out"
  assert_contains "$out" "status=exists" "mate rerun with a quoted title was not reported as existing"
  out=$(t "$H" new shared "Shared thing" --owner alpha) || fail "explicit owner failed: $out"
  assert_contains "$out" "owner=alpha" "--owner was ignored"
  printf -- '- beta2 - more (home: %s; scope: s; projects: beta; added 2026-07-09)\n' "$B" >> "$H/data/secondmates.md"
  local rc=0
  out=$(t "$H" new beta "Ambiguous") || rc=$?
  [ "$rc" -ne 0 ] || fail "ambiguous project owner was guessed"
  pass "new files a ticket in the owning home, converges on rerun, and refuses ambiguous owners"
}

test_owner_lookup_names_main_mate_and_absent
test_edit_routes_to_a_mate_applies_acks_and_replays
test_edit_rejects_invalid_and_closed_without_partial_effect
test_edit_of_a_moved_ticket_reports_the_new_owner_and_retry_follows
test_mate_requester_edits_primary_and_sibling_tickets_through_its_parent
test_edit_with_an_unreadable_owner_is_pending_and_retry_converges
test_mate_without_a_local_parent_route_leaves_an_edit_pending
test_replay_after_a_handoff_is_not_applied_twice
test_new_ticket_lands_in_the_owning_home

echo "ALL TESTS PASSED"
