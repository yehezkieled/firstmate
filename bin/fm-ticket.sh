#!/usr/bin/env bash
# fm-ticket.sh - ticket ownership lookup, routed ticket edits, and one-step
# new tickets across the primary home and its secondmate homes.
#
# MODEL. A ticket (a backlog item) has exactly one owning home. Ownership moves
# only by handoff (bin/fm-backlog-handoff.sh, in every direction), the other side
# reads by rollup (bin/fm-fleet-snapshot.sh, which names each row's owner), and a
# change crosses the boundary as a routed request. There is no two-way mirror:
# the owner is the only writer, and a request is applied in the owner's home by
# that home's own tasks-axi under its own locks. bin/fm-ticket-lib.sh owns the
# "which home carries this key" lookup that every router shares.
#
# Usage:
#   fm-ticket.sh owner <key> [--json]
#   fm-ticket.sh new <project> <title> [--key <key>] [--body <text> | --body-file <path>]
#       [--priority <0-4>] [--kind <kind>] [--blocked-by <id>]... [--owner <main|secondmate-id>]
#   fm-ticket.sh edit <key> [--request-id <id>] [--json] <edit>...
#       <edit> is one or more of: --title <text>, --body <text> | --body-file <path>
#       (replace, archiving the previous body), --note <text> (append a dated note),
#       --priority <0-4>, --block <id>, --unblock <id>,
#       --hold <reason> [--until YYYY-MM-DD] [--hold-kind <captain|external|load|parked|future>],
#       --unhold
#   fm-ticket.sh status <request-id> [--json]
#   fm-ticket.sh retry <request-id> [--json]
#   fm-ticket.sh resume-pending
#   fm-ticket.sh locate-local <key>          internal: section of <key> in THIS home
#   fm-ticket.sh route [--requester <label>] internal: route a request payload from stdin
#   fm-ticket.sh apply [--requester <label>] internal: apply a request payload from stdin
#
# OWNER. Prints key=value lines: key, owner (main, a secondmate id, ambiguous, or
# none), section, remote, home, candidates, and unreadable (registered mates
# whose backlog could not be read, and `parent` when a secondmate home cannot
# ask its parent; absence there is unknown, never a fact). From a local
# secondmate home that does not carry the key, the lookup continues in its
# parent home.
#
# EDIT is the routed request for a ticket this home may not own. It builds a
# payload with a correlation id (--request-id, or a minted one; a caller that
# supplies its own id gets idempotent replay), journals it durably under
# state/ticket-requests/<id>.req BEFORE any delivery, resolves the owner, and
# delivers it: the owner's own `apply` runs in the owner's home (a local mate
# directly, a remote mate through bin/fm-on.sh), so delivery and application are
# one synchronous act and the acknowledgement is real, not a best-effort note.
# From a secondmate home, a key that home does not carry is routed to its local
# parent, which resolves the owner among itself and all of its mates, so a mate
# can edit a primary-owned ticket and a ticket owned by a sibling mate. A
# secondmate home whose local parent is unavailable leaves such a request
# pending rather than reporting it absent; one whose parent route is remote
# cannot route it at all, so the request is rejected as unsupported.
# The owner's apply is idempotent by request id: a durable receipt under
# state/ticket-receipts/<id>.receipt in the owner's home answers a replay with
# the original outcome, and a replay carrying different content is rejected.
# The owner also records "Ticket request <id> applied (<hash>)." in the ticket
# body itself, so a request replayed after the ticket was handed off is
# recognized by the new owner and never applied twice.
# The edits of one request are validated first, then applied one at a time with
# per-edit progress recorded, so a crash mid-way converges on the same retry.
# Edits ride the existing owners: title, body, priority, block and unblock go
# through tasks-axi update/block/unblock, and a captain-kind hold goes through
# bin/fm-captain-hold.sh hold (the one creator of captain holds); a captain hold
# is released only by its keyed answer, so --unhold of one is rejected. A ticket
# in ## Done is closed and rejected. The owning mate is told with one
# fire-and-forget doorbell after a first application, best-effort: the edit is
# already durable in its backlog.
#
# Outcome and exit status, recorded in state/ticket-requests/<id>.result and
# printed as key=value lines (status, owner, detail):
#   0  applied (or replayed: the original outcome)
#   2  rejected: invalid edit, closed ticket, ambiguous owner, id reuse
#   3  moved or absent: the believed owner no longer carries the ticket. A moved
#      ticket reports its new owner; `retry` re-resolves and delivers there.
#   4  pending: the owner could not be reached or read (transport down, home
#      unreadable). Nothing was lost: `retry <id>` or `resume-pending`
#      (bin/fm-bootstrap.sh runs it) redelivers the same journaled request.
#
# NEW is the one-step "new ticket in project X". The owner is --owner, or else
# the single registered secondmate whose `projects:` list names the project
# (several matches is refused until --owner picks one; none means this home),
# and a local-only project is always this home's. The ticket is filed Queued
# with tasks-axi add and, for a mate, moved with bin/fm-backlog-handoff.sh so it
# lands in the owning home with the handoff's wake. A rerun with the same key and
# title converges: a ticket already filed or already handed off is reported, not
# duplicated, and a failed handoff leaves it Queued in this home for the rerun.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
BACKLOG="$DATA/backlog.md"
REQ_DIR="$STATE/ticket-requests"
RECEIPT_DIR="$STATE/ticket-receipts"
PAYLOAD_SCHEMA=fm-ticket-edit.v1
RESULT_TAG=FM_TICKET_RESULT

# shellcheck source=bin/fm-ticket-lib.sh
. "$SCRIPT_DIR/fm-ticket-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-secondmate-parent-lib.sh
. "$SCRIPT_DIR/fm-secondmate-parent-lib.sh"

die() { printf 'fm-ticket: %s\n' "$*" >&2; exit "${DIE_RC:-2}"; }

usage() { sed -n '2,/^set -u/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

b64e() { printf '%s' "$1" | base64 | tr -d '\n'; }
b64d() { printf '%s' "$1" | { base64 -d 2>/dev/null || base64 -D; }; }

sha256_text() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 | awk '{print $1}'; else sha256sum | awk '{print $1}'; fi
}

now_epoch() { date +%s; }
today() { date -u +%Y-%m-%d; }

request_id_valid() {
  case "$1" in '' | *[!A-Za-z0-9._-]*) return 1 ;; esac
  [ "${#1}" -le 64 ]
}

mint_request_id() { printf 'r-%s' "$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')"; }

# Atomic private write of stdin to <path>.
write_atomic() { # <path>
  local path=$1 tmp
  mkdir -p "$(dirname "$path")" || return 1
  tmp=$(umask 077; mktemp "$(dirname "$path")/.tmp.XXXXXX") || return 1
  if cat > "$tmp" && chmod 600 "$tmp" && mv -f -- "$tmp" "$path"; then return 0; fi
  rm -f -- "$tmp"
  return 1
}

kv_get() { # <file> <key>
  sed -n "s/^$2=//p" "$1" 2>/dev/null | head -1
}

# This home's identity label for requests it originates: its mate id, or main.
home_label() {
  local id
  if id=$(fm_parent_channel_marker_id 2>/dev/null) && [ -n "$id" ]; then printf '%s\n' "$id"; else printf 'main\n'; fi
}
fm_parent_channel_marker_id() {
  local marker="$FM_HOME/.fm-secondmate-home" id
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
  id=$(cat "$marker" 2>/dev/null) || return 1
  fm_ticket_key_valid "$id" || return 1
  printf '%s\n' "$id"
}

# The local parent home of this secondmate home, printed; non-zero otherwise.
local_parent_home() {
  fm_secondmate_parent_record_parse "$FM_HOME/.fm-secondmate-parent" || return 1
  [ "$FM_SECONDMATE_PARENT_ROUTE" = local ] && [ -n "$FM_SECONDMATE_PARENT_HOME" ] || return 1
  [ -d "$FM_SECONDMATE_PARENT_HOME" ] || return 1
  printf '%s\n' "$FM_SECONDMATE_PARENT_HOME"
}

run_in_parent() { # <parent-home> <subcommand> [args...]
  local parent=$1
  shift
  env -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE \
    -u FM_PROJECTS_OVERRIDE -u FM_ROOT_OVERRIDE -u FM_PENDING_REPLY_DIR_OVERRIDE \
    FM_HOME="$parent" "$SCRIPT_DIR/fm-ticket.sh" "$@"
}

# --- owner / locate-local -----------------------------------------------------

cmd_locate_local() {
  local key=${1:-} section
  fm_ticket_key_valid "$key" || die "unsafe ticket key: $key"
  section=$(fm_backlog_key_section "$BACKLOG" "$key") || { echo fm-ticket-absent; exit 1; }
  printf '%s\n' "$section"
}

owner_json() { # key owner section remote home candidates unreadable
  jq -n --arg key "$1" --arg owner "$2" --arg section "$3" --arg remote "$4" --arg home "$5" \
    --arg candidates "$6" --arg unreadable "$7" \
    '{key:$key,owner:$owner,section:($section | ltrimstr("## ")),remote:($remote == "1"),
      home:(if $home == "" then null else $home end),
      candidates:($candidates | split(" ") | map(select(length > 0))),
      unreadable:($unreadable | split(" ") | map(select(length > 0)))}'
}

# The label of owner <owner> as seen from this home: `main` from fm_ticket_locate
# means this home, which in a secondmate home is that mate's own id.
owner_label() { # <owner>
  if [ "$1" = main ]; then home_label; else printf '%s\n' "$1"; fi
}

# Resolve the owner in the widest scope this home can see; sets the FM_TICKET_*
resolve_owner() { # <key>
  local key=$1 rc=0 parent out
  fm_ticket_locate "$DATA" "$key" || rc=$?
  [ "$rc" -ne 0 ] || FM_TICKET_OWNER=$(owner_label "$FM_TICKET_OWNER")
  [ "$rc" -eq 1 ] || return "$rc"
  if ! parent=$(local_parent_home); then
    [ "$(home_label)" = main ] || FM_TICKET_UNREADABLE="$FM_TICKET_UNREADABLE parent"
  else
    out=$(run_in_parent "$parent" owner "$key" 2>/dev/null) || true
    if [ -n "$out" ]; then
      FM_TICKET_OWNER=$(printf '%s\n' "$out" | sed -n 's/^owner=//p' | head -1)
      FM_TICKET_SECTION=$(printf '%s\n' "$out" | sed -n 's/^section=//p' | head -1)
      FM_TICKET_CANDIDATES=$(printf '%s\n' "$out" | sed -n 's/^candidates=//p' | head -1)
      FM_TICKET_UNREADABLE="$FM_TICKET_UNREADABLE $(printf '%s\n' "$out" | sed -n 's/^unreadable=//p' | head -1)"
      FM_TICKET_HOME=
      FM_TICKET_REMOTE=0
      case "$FM_TICKET_OWNER" in
        none | '') return 1 ;;
        ambiguous) return 2 ;;
        *) return 0 ;;
      esac
    fi
    FM_TICKET_UNREADABLE="$FM_TICKET_UNREADABLE parent"
  fi
  return 1
}

cmd_owner() {
  local key='' json=0 rc=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --json) json=1 ;;
      -*) die "unknown option: $1" ;;
      *) [ -z "$key" ] || die "owner takes one key"; key=$1 ;;
    esac
    shift
  done
  fm_ticket_key_valid "$key" || die "owner requires a safe ticket key"
  resolve_owner "$key" || rc=$?
  local owner=$FM_TICKET_OWNER
  [ -n "$owner" ] || owner=none
  if [ "$json" -eq 1 ]; then
    command -v jq >/dev/null 2>&1 || die "jq is required for --json"
    owner_json "$key" "$owner" "$FM_TICKET_SECTION" "$FM_TICKET_REMOTE" "$FM_TICKET_HOME" \
      "$FM_TICKET_CANDIDATES" "$FM_TICKET_UNREADABLE"
  else
    printf 'key=%s\nowner=%s\nsection=%s\nremote=%s\nhome=%s\ncandidates=%s\nunreadable=%s\n' \
      "$key" "$owner" "${FM_TICKET_SECTION#\#\# }" "$FM_TICKET_REMOTE" "$FM_TICKET_HOME" \
      "$FM_TICKET_CANDIDATES" "$(printf '%s' "$FM_TICKET_UNREADABLE" | xargs)"
  fi
  case "$rc" in 0) exit 0 ;; 2) exit 2 ;; *) exit 1 ;; esac
}

# --- payload ------------------------------------------------------------------

# A payload is line-oriented: schema, request, key, then one `op=` line per edit
# whose operands are base64 (text) or plain tokens, tab separated.
build_payload() { # <request-id> <key> <ops-file>  -> stdout
  printf 'schema=%s\nrequest=%s\nkey=%s\n' "$PAYLOAD_SCHEMA" "$1" "$2"
  cat "$3"
}

payload_ops_hash() { # <payload-file>: hash of the content that defines the edit
  grep -v '^request=' "$1" | sha256_text
}

validate_payload_shape() { # <payload-file>; sets PAYLOAD_REQUEST, PAYLOAD_KEY
  local file=$1 line ops=0 schema_n=0
  PAYLOAD_REQUEST=$(kv_get "$file" request)
  PAYLOAD_KEY=$(kv_get "$file" key)
  request_id_valid "$PAYLOAD_REQUEST" || { PAYLOAD_ERROR="payload has an unsafe request id"; return 1; }
  fm_ticket_key_valid "$PAYLOAD_KEY" || { PAYLOAD_ERROR="payload has an unsafe ticket key"; return 1; }
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "schema=$PAYLOAD_SCHEMA") schema_n=$((schema_n + 1)) ;;
      request=* | key=*) ;;
      op=title$'\t'* | op=body$'\t'* | op=note$'\t'* | op=priority$'\t'* | op=block$'\t'* | op=unblock$'\t'* | op=unhold)
        ops=$((ops + 1)) ;;
      op=hold$'\t'*) ops=$((ops + 1)) ;;
      '') ;;
      *) PAYLOAD_ERROR="payload has an unrecognized line"; return 1 ;;
    esac
  done < "$file"
  [ "$schema_n" -eq 1 ] || { PAYLOAD_ERROR="payload schema is missing or unsupported"; return 1; }
  [ "$ops" -gt 0 ] || { PAYLOAD_ERROR="payload carries no edit"; return 1; }
  return 0
}

# --- result record ------------------------------------------------------------

result_line() { # status owner detail
  printf '%s status=%s owner=%s detail=%s\n' "$RESULT_TAG" "$1" "${2:-}" "$(printf '%s' "${3:-}" | tr '\n\t' '  ')"
}

parse_result() { # <text>; sets R_STATUS R_OWNER R_DETAIL from the last result line
  local line
  R_STATUS=
  R_OWNER=
  R_DETAIL=
  line=$(printf '%s\n' "$1" | grep "^$RESULT_TAG " | tail -1)
  [ -n "$line" ] || return 1
  R_STATUS=$(printf '%s' "$line" | sed -n 's/^[A-Z_]* status=\([^ ]*\) .*/\1/p')
  R_OWNER=$(printf '%s' "$line" | sed -n 's/.* owner=\([^ ]*\) detail=.*/\1/p')
  R_DETAIL=$(printf '%s' "$line" | sed -n 's/.* detail=//p')
  [ -n "$R_STATUS" ]
}

record_result() { # <request-id> <status> <owner> <detail>
  {
    printf 'request=%s\nstatus=%s\nowner=%s\nat=%s\ndetail=%s\n' \
      "$1" "$2" "$3" "$(now_epoch)" "$(printf '%s' "$4" | tr '\n\t' '  ')"
  } | write_atomic "$REQ_DIR/$1.result"
}

print_result() { # <request-id> [json]
  local f="$REQ_DIR/$1.result"
  [ -f "$f" ] || { printf 'request=%s\nstatus=unknown\n' "$1"; return 1; }
  if [ "${2:-0}" = 1 ]; then
    command -v jq >/dev/null 2>&1 || die "jq is required for --json"
    jq -n --arg request "$(kv_get "$f" request)" --arg status "$(kv_get "$f" status)" \
      --arg owner "$(kv_get "$f" owner)" --arg at "$(kv_get "$f" at)" --arg detail "$(kv_get "$f" detail)" \
      '{request:$request,status:$status,owner:$owner,at:($at | tonumber? // null),detail:$detail}'
  else
    cat "$f"
  fi
}

status_rc() { # <status>
  case "$1" in
    applied | replay) echo 0 ;;
    rejected) echo 2 ;;
    moved | absent) echo 3 ;;
    *) echo 4 ;;
  esac
}

# --- apply (runs in the owning home) -------------------------------------------

# A `tasks-axi show` field value, decoded: tasks-axi quotes a value that holds
# special characters as a JSON string.
shown_value() { # <raw-value>
  case "$1" in
    \"*\") printf '%s' "$1" | jq -r . ;;
    *) printf '%s' "$1" ;;
  esac
}

show_body() { # <key>: the current body text of a ticket
  local shown raw
  shown=$("$SCRIPT_DIR/fm-tasks-axi.sh" show "$1" --full 2>/dev/null) || return 1
  raw=$(shown_value "$(printf '%s\n' "$shown" | sed -n 's/^  body: //p' | head -1)")
  [ "$raw" = - ] || printf '%s' "$raw"
}

show_field_plain() { # <key> <field>
  local shown
  shown=$("$SCRIPT_DIR/fm-tasks-axi.sh" show "$1" --full 2>/dev/null) || return 1
  shown_value "$(printf '%s\n' "$shown" | sed -n "s/^  $2: //p" | head -1)"
}

# The ops hash a request id was applied with, from the marker line the owner
# writes into the ticket body itself, so the record travels with a handoff.
request_marker_hash() { # <key> <request-id>
  local body
  body=$(show_body "$1") || return 1
  printf '%s\n' "$body" | awk -v req="$2" '$1 == "Ticket" && $2 == "request" && $3 == req && $4 == "applied" {
    h = $5; gsub(/[().]/, "", h); print h; exit }'
}

request_markers() { # <key>: every request marker line in the ticket body
  local body
  body=$(show_body "$1") || return 1
  printf '%s\n' "$body" | awk '$1 == "Ticket" && $2 == "request" && $4 == "applied" && NF == 5'
}

record_request_marker() { # <key> <request-id> <hash>
  local tmp old
  old=$(show_body "$1") || return 1
  tmp=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-ticket-body.XXXXXX") || return 1
  {
    [ -z "$old" ] || printf '%s\n' "$old"
    printf 'Ticket request %s applied (%s).\n' "$2" "${3:0:16}"
  } > "$tmp"
  if "$SCRIPT_DIR/fm-tasks-axi.sh" update "$1" --body-file "$tmp" >/dev/null 2>&1; then
    rm -f -- "$tmp"
    return 0
  fi
  rm -f -- "$tmp"
  return 1
}

# Validate every operand before any is applied; sets REJECT on the first fault.
validate_ops() { # <payload-file>
  local file=$1 line op a b c d
  REJECT=
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in op=*) ;; *) continue ;; esac
    IFS=$'\t' read -r op a b c <<< "${line#op=}"
    case "$op" in
      title)
        d=$(b64d "$a")
        [ -n "$d" ] || { REJECT="title is empty"; return 1; }
        case "$d" in *$'\n'*) REJECT="title must be one line"; return 1 ;; esac
        ;;
      body)
        [ -n "$(b64d "$a")" ] || { REJECT="body is empty"; return 1; }
        ;;
      note)
        [ -n "$(b64d "$a")" ] || { REJECT="note is empty"; return 1; }
        ;;
      priority)
        case "$a" in [0-4]) ;; *) REJECT="priority must be an integer 0-4"; return 1 ;; esac
        ;;
      block | unblock)
        fm_ticket_key_valid "$a" || { REJECT="unsafe dependency id: $a"; return 1; }
        [ "$a" != "$PAYLOAD_KEY" ] || { REJECT="a ticket cannot block itself"; return 1; }
        if [ "$op" = block ] && ! fm_backlog_key_section "$BACKLOG" "$a" >/dev/null; then
          REJECT="blocker $a is not in the owning home's backlog; a dependency cannot cross homes"
          return 1
        fi
        ;;
      hold)
        d=$(b64d "$a")
        [ -n "$d" ] || { REJECT="hold reason is empty"; return 1; }
        case "$d" in *$'\n'*) REJECT="hold reason must be one line"; return 1 ;; esac
        case "${b:-}" in '' | [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;; *) REJECT="hold --until must be YYYY-MM-DD"; return 1 ;; esac
        case "${c:-captain}" in captain | external | load | parked | future) ;; *) REJECT="unknown hold kind: ${c:-}"; return 1 ;; esac
        ;;
      unhold) ;;
    esac
  done < "$file"
  return 0
}

apply_one_op() { # <key> <request-id> <requester> <op-line-without-op=>; exit nonzero on failure
  local key=$1 req=$2 requester=$3 spec=$4 op a b c text old tmp out
  IFS=$'\t' read -r op a b c <<< "$spec"
  case "$op" in
    title)
      "$SCRIPT_DIR/fm-tasks-axi.sh" update "$key" --title "$(b64d "$a")" >/dev/null 2>&1 ;;
    priority)
      "$SCRIPT_DIR/fm-tasks-axi.sh" update "$key" --priority "$a" >/dev/null 2>&1 ;;
    block)
      "$SCRIPT_DIR/fm-tasks-axi.sh" block "$key" --by "$a" >/dev/null 2>&1 ;;
    unblock)
      "$SCRIPT_DIR/fm-tasks-axi.sh" unblock "$key" --by "$a" >/dev/null 2>&1 ;;
    body | note)
      tmp=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-ticket-body.XXXXXX") || return 1
      text=$(b64d "$a")
      if [ "$op" = body ]; then
        old=$(request_markers "$key") || { rm -f -- "$tmp"; return 1; }
        {
          printf '%s\n' "$text"
          [ -z "$old" ] || printf '%s\n' "$old"
        } > "$tmp"
      else
        old=$(show_body "$key") || { rm -f -- "$tmp"; return 1; }
        {
          [ -z "$old" ] || printf '%s\n' "$old"
          printf 'Note (%s, %s, request %s): %s\n' "$requester" "$(today)" "$req" "$text"
        } > "$tmp"
      fi
      if "$SCRIPT_DIR/fm-tasks-axi.sh" update "$key" --body-file "$tmp" --archive-body >/dev/null 2>&1; then
        rm -f -- "$tmp"
      else
        rm -f -- "$tmp"
        return 1
      fi
      ;;
    hold)
      text=$(b64d "$a")
      if [ "${c:-captain}" = captain ]; then
        if [ -n "${b:-}" ]; then
          "$SCRIPT_DIR/fm-captain-hold.sh" hold "$key" --reason "$text" --until "$b" >/dev/null 2>&1
        else
          "$SCRIPT_DIR/fm-captain-hold.sh" hold "$key" --reason "$text" >/dev/null 2>&1
        fi
      else
        if [ -n "${b:-}" ]; then
          "$SCRIPT_DIR/fm-tasks-axi.sh" hold "$key" --reason "$text" --kind "$c" --until "$b" >/dev/null 2>&1
        else
          "$SCRIPT_DIR/fm-tasks-axi.sh" hold "$key" --reason "$text" --kind "$c" >/dev/null 2>&1
        fi
      fi
      ;;
    unhold)
      "$SCRIPT_DIR/fm-tasks-axi.sh" unhold "$key" >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
  out=$?
  return "$out"
}

cmd_apply() {
  local requester=unknown payload section hash receipt progress idx=0 line lock rc=0 total recorded hold_kind
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --requester) shift; requester=${1:-unknown} ;;
      *) die "unknown option: $1" ;;
    esac
    shift
  done
  fm_ticket_key_valid "$requester" || requester=unknown
  payload=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-ticket-payload.XXXXXX") || die "cannot stage the payload"
  cat > "$payload"
  trap 'rm -f -- "$payload"' EXIT
  PAYLOAD_ERROR=
  if ! validate_payload_shape "$payload"; then
    result_line rejected "$(home_label)" "$PAYLOAD_ERROR"
    exit 2
  fi
  hash=$(payload_ops_hash "$payload")
  receipt="$RECEIPT_DIR/$PAYLOAD_REQUEST.receipt"
  progress="$RECEIPT_DIR/$PAYLOAD_REQUEST.progress"
  lock="$STATE/.ticket-apply-$PAYLOAD_KEY.lock"
  mkdir -p "$STATE" "$RECEIPT_DIR" || die "cannot create the receipt directory"
  fm_lock_acquire_wait "$lock"
  # shellcheck disable=SC2064
  trap "fm_lock_release '$lock'; rm -f -- '$payload'" EXIT
  if [ -f "$receipt" ]; then
    if [ "$(kv_get "$receipt" hash)" = "$hash" ]; then
      result_line replay "$(home_label)" "already applied: $(kv_get "$receipt" detail)"
      exit 0
    fi
    result_line rejected "$(home_label)" "request id $PAYLOAD_REQUEST was already used with different content"
    exit 2
  fi
  if ! section=$(fm_backlog_key_section "$BACKLOG" "$PAYLOAD_KEY"); then
    result_line absent "$(home_label)" "ticket $PAYLOAD_KEY is not in this home's backlog"
    exit 3
  fi
  if [ "$section" = '## Done' ]; then
    result_line rejected "$(home_label)" "ticket $PAYLOAD_KEY is closed"
    exit 2
  fi
  command -v tasks-axi >/dev/null 2>&1 || { result_line pending "$(home_label)" "tasks-axi is not available"; exit 1; }
  recorded=$(request_marker_hash "$PAYLOAD_KEY" "$PAYLOAD_REQUEST") \
    || { result_line pending "$(home_label)" "ticket $PAYLOAD_KEY could not be read to check for an earlier application; the request is retryable"; exit 1; }
  if [ -n "$recorded" ]; then
    if [ "$recorded" = "${hash:0:16}" ]; then
      result_line replay "$(home_label)" "already applied: recorded on ticket $PAYLOAD_KEY"
      exit 0
    fi
    result_line rejected "$(home_label)" "request id $PAYLOAD_REQUEST was already used with different content"
    exit 2
  fi
  if ! validate_ops "$payload"; then
    result_line rejected "$(home_label)" "$REJECT"
    exit 2
  fi
  if grep -q '^op=unhold' "$payload"; then
    hold_kind=$(show_field_plain "$PAYLOAD_KEY" hold_kind) \
      || { result_line pending "$(home_label)" "ticket $PAYLOAD_KEY could not be read to check its hold kind; the request is retryable"; exit 1; }
    if [ "$hold_kind" = captain ]; then
      result_line rejected "$(home_label)" "a captain hold is released only by its keyed answer"
      exit 2
    fi
  fi
  total=$(grep -c '^op=' "$payload")
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in op=*) ;; *) continue ;; esac
    idx=$((idx + 1))
    if [ -f "$progress" ] && grep -qx "$idx" "$progress"; then continue; fi
    if apply_one_op "$PAYLOAD_KEY" "$PAYLOAD_REQUEST" "$requester" "${line#op=}"; then
      printf '%s\n' "$idx" >> "$progress"
    else
      rc=1
      break
    fi
  done < "$payload"
  if [ "$rc" -ne 0 ]; then
    result_line pending "$(home_label)" "edit $idx of $total failed in the owning home; the request is retryable"
    exit 1
  fi
  record_request_marker "$PAYLOAD_KEY" "$PAYLOAD_REQUEST" "$hash" \
    || { result_line pending "$(home_label)" "applied but the request could not be recorded on the ticket"; exit 1; }
  {
    printf 'request=%s\nkey=%s\nhash=%s\nrequester=%s\nat=%s\n' "$PAYLOAD_REQUEST" "$PAYLOAD_KEY" "$hash" "$requester" "$(now_epoch)"
    printf 'detail=%s edit(s) applied\n' "$total"
  } | write_atomic "$receipt" || { result_line pending "$(home_label)" "applied but the receipt could not be written"; exit 1; }
  rm -f -- "$progress"
  result_line applied "$(home_label)" "$total edit(s) applied"
  exit 0
}

# --- routing (runs in the requester's home) -------------------------------------

# Deliver the journaled payload at <file> to its owner and print the result line.
# Sets ROUTE_RC to the request's exit status.
route_payload() { # <payload-file> <requester-label>
  local file=$1 requester=$2 key req out rc=0 owner parent believed label
  PAYLOAD_ERROR=
  validate_payload_shape "$file" || { result_line rejected "$(home_label)" "$PAYLOAD_ERROR"; ROUTE_RC=2; return; }
  key=$PAYLOAD_KEY
  req=$PAYLOAD_REQUEST
  fm_ticket_locate "$DATA" "$key" || rc=$?
  case "$rc" in
    2)
      result_line rejected ambiguous "ticket $key is carried by more than one home ($FM_TICKET_CANDIDATES); resolve the duplicate before editing"
      ROUTE_RC=2
      return
      ;;
    1)
      if parent=$(local_parent_home); then
        out=$(run_in_parent "$parent" route --requester "$requester" < "$file" 2>&1) || true
        if parse_result "$out"; then
          printf '%s\n' "$out" | grep "^$RESULT_TAG " | tail -1
          ROUTE_RC=$(status_rc "$R_STATUS")
        else
          result_line pending parent "the parent home gave no result"
          ROUTE_RC=4
        fi
        return
      fi
      if [ "$(home_label)" != main ] && fm_secondmate_parent_record_parse "$FM_HOME/.fm-secondmate-parent" \
        && [ "$FM_SECONDMATE_PARENT_ROUTE" != local ]; then
        result_line rejected parent "unsupported: ticket $key is not in this secondmate home, and its $FM_SECONDMATE_PARENT_ROUTE parent route cannot carry a routed edit; edit it in the owning home"
        ROUTE_RC=2
        return
      fi
      if [ "$(home_label)" != main ]; then
        result_line pending parent "ticket $key is not in this secondmate home and it has no local parent route to ask its parent; retry once the parent is reachable"
        ROUTE_RC=4
        return
      fi
      if [ -n "$FM_TICKET_UNREADABLE" ]; then
        result_line pending unknown "ticket $key was not found and these homes could not be read: $FM_TICKET_UNREADABLE"
        ROUTE_RC=4
        return
      fi
      result_line absent none "no home carries ticket $key"
      ROUTE_RC=3
      return
      ;;
  esac
  owner=$FM_TICKET_OWNER
  believed=$owner
  label=$(owner_label "$owner")
  if [ "$owner" = main ]; then
    out=$(cmd_apply_here "$file" "$requester") && rc=0 || rc=$?
  else
    out=$(fm_ticket_run_in_mate "$DATA" "$owner" fm-ticket.sh apply --requester "$requester" < "$file" 2>&1) && rc=0 || rc=$?
  fi
  if ! parse_result "$out"; then
    result_line pending "$label" "owner $label could not be reached or gave no result (exit $rc)"
    ROUTE_RC=4
    return
  fi
  if [ "$R_STATUS" = absent ]; then
    # The believed owner no longer carries it: report where it went.
    rc=0
    fm_ticket_locate "$DATA" "$key" || rc=$?
    if [ "$rc" -eq 0 ] && [ "$FM_TICKET_OWNER" != "$believed" ]; then
      owner=$(owner_label "$FM_TICKET_OWNER")
      result_line moved "$owner" "ticket $key moved from $label to $owner; retry delivers it there"
      ROUTE_RC=3
      return
    fi
    result_line absent none "ticket $key is no longer in $label and no readable home carries it"
    ROUTE_RC=3
    return
  fi
  R_OWNER=$label
  result_line "$R_STATUS" "$label" "$R_DETAIL"
  ROUTE_RC=$(status_rc "$R_STATUS")
  case "$R_STATUS" in
    applied) notify_owner "$owner" "$key" "$req" "$requester" ;;
  esac
}

# Apply in THIS home (the primary owns the ticket): same code path as a mate.
cmd_apply_here() { # <payload-file> <requester>
  "$SCRIPT_DIR/fm-ticket.sh" apply --requester "$2" < "$1"
}

# Tell the owning mate its backlog changed under it. Best-effort: the edit is
# already durable and acknowledged, and the doorbell never changes the outcome.
notify_owner() { # <owner> <key> <request-id> <requester>
  local owner=$1 key=$2 req=$3 requester=$4 delivery
  [ "$owner" != main ] || return 0
  [ "$requester" != "$owner" ] || return 0
  delivery=$(printf '%s' "$req" | sha256_text | cut -c1-16)
  FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-send.sh" "$owner" --fire-and-forget "$delivery" \
    "Ticket $key in your backlog was edited by $requester (request $req). Re-read it before acting on it." \
    >/dev/null 2>&1 || printf 'fm-ticket: note: could not ring %s about the edit (it is durable in its backlog)\n' "$owner" >&2
  return 0
}

cmd_route() {
  local requester=unknown file
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --requester) shift; requester=${1:-unknown} ;;
      *) die "unknown option: $1" ;;
    esac
    shift
  done
  fm_ticket_key_valid "$requester" || requester=unknown
  file=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-ticket-route.XXXXXX") || die "cannot stage the request"
  cat > "$file"
  route_payload "$file" "$requester"
  rm -f -- "$file"
  exit "${ROUTE_RC:-4}"
}

# --- edit / status / retry --------------------------------------------------------

deliver_journaled() { # <request-id> <json>
  local req=$1 json=${2:-0} file="$REQ_DIR/$1.req" out requester
  requester=$(home_label)
  # ROUTE_RC is set in this shell, so capture the text through a file, not $().
  ROUTE_RC=4
  route_payload "$file" "$requester" > "$REQ_DIR/.last.$$" 2>&1 || true
  out=$(cat "$REQ_DIR/.last.$$")
  rm -f -- "$REQ_DIR/.last.$$"
  if parse_result "$out"; then
    record_result "$req" "$R_STATUS" "$R_OWNER" "$R_DETAIL" || die "cannot record the outcome of $req"
  else
    record_result "$req" pending unknown "no result was produced" || true
  fi
  print_result "$req" "$json"
  exit "$ROUTE_RC"
}

cmd_edit() {
  local key='' req='' json=0 ops tmp payload hash existing
  ops=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-ticket-ops.XXXXXX") || die "cannot stage the request"
  trap 'rm -f -- "$ops"' EXIT
  [ "$#" -ge 1 ] || { usage >&2; exit 2; }
  key=$1
  shift
  fm_ticket_key_valid "$key" || die "edit requires a safe ticket key"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --request-id) shift; req=${1:-} ;;
      --json) json=1 ;;
      --title) shift; printf 'op=title\t%s\n' "$(b64e "${1-}")" >> "$ops" ;;
      --body) shift; printf 'op=body\t%s\n' "$(b64e "${1-}")" >> "$ops" ;;
      --body-file) shift; [ -f "${1:-}" ] || die "--body-file is not a file: ${1:-}"
        printf 'op=body\t%s\n' "$(b64e "$(cat "$1")")" >> "$ops" ;;
      --note) shift; printf 'op=note\t%s\n' "$(b64e "${1-}")" >> "$ops" ;;
      --priority) shift; printf 'op=priority\t%s\n' "${1-}" >> "$ops" ;;
      --block) shift; printf 'op=block\t%s\n' "${1-}" >> "$ops" ;;
      --unblock) shift; printf 'op=unblock\t%s\n' "${1-}" >> "$ops" ;;
      --hold)
        shift
        local reason=${1-} until='' kind=captain
        while [ "$#" -ge 2 ]; do
          case "$2" in
            --until) until=${3:-}; shift 2 ;;
            --hold-kind) kind=${3:-}; shift 2 ;;
            *) break ;;
          esac
        done
        printf 'op=hold\t%s\t%s\t%s\n' "$(b64e "$reason")" "$until" "$kind" >> "$ops"
        ;;
      --unhold) printf 'op=unhold\n' >> "$ops" ;;
      *) die "unknown option: $1" ;;
    esac
    shift
  done
  [ -s "$ops" ] || die "edit needs at least one change (--title, --body, --note, --priority, --block, --unblock, --hold, --unhold)"
  [ -n "$req" ] || req=$(mint_request_id)
  request_id_valid "$req" || die "unsafe request id: $req"
  payload=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-ticket-payload.XXXXXX") || die "cannot stage the request"
  build_payload "$req" "$key" "$ops" > "$payload"
  hash=$(payload_ops_hash "$payload")
  existing="$REQ_DIR/$req.req"
  if [ -f "$existing" ]; then
    if [ "$(payload_ops_hash "$existing")" != "$hash" ]; then
      rm -f -- "$payload"
      die "request id $req was already used with different content"
    fi
  else
    write_atomic "$existing" < "$payload" || { rm -f -- "$payload"; die "cannot journal the request"; }
  fi
  rm -f -- "$payload"
  record_result "$req" pending "" "journaled; delivering" || true
  deliver_journaled "$req" "$json"
}

cmd_status() {
  local req='' json=0
  while [ "$#" -gt 0 ]; do
    case "$1" in --json) json=1 ;; -*) die "unknown option: $1" ;; *) req=$1 ;; esac
    shift
  done
  request_id_valid "$req" || die "status requires a request id"
  print_result "$req" "$json"
}

cmd_retry() {
  local req='' json=0
  while [ "$#" -gt 0 ]; do
    case "$1" in --json) json=1 ;; -*) die "unknown option: $1" ;; *) req=$1 ;; esac
    shift
  done
  request_id_valid "$req" || die "retry requires a request id"
  [ -f "$REQ_DIR/$req.req" ] || die "no journaled request $req"
  deliver_journaled "$req" "$json"
}

cmd_resume_pending() {
  local f req status failed=0
  [ -d "$REQ_DIR" ] || exit 0
  for f in "$REQ_DIR"/*.result; do
    [ -e "$f" ] || continue
    status=$(kv_get "$f" status)
    [ "$status" = pending ] || continue
    req=$(basename "$f" .result)
    request_id_valid "$req" || continue
    [ -f "$REQ_DIR/$req.req" ] || continue
    "$SCRIPT_DIR/fm-ticket.sh" retry "$req" >/dev/null 2>&1 || failed=1
  done
  exit "$failed"
}

# --- new ------------------------------------------------------------------------

slugify() { # <text>
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | LC_ALL=C sed 's/[^a-z0-9]\{1,\}/-/g; s/^-//; s/-$//' | cut -c1-40 | sed 's/-$//'
}

cmd_new() {
  local project='' title='' key='' body='' body_file='' priority='' kind='' owner='' blocked=() mode ids id matches=() rc
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  project=$1
  title=$2
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --key) shift; key=${1:-} ;;
      --body) shift; body=${1-} ;;
      --body-file) shift; body_file=${1:-} ;;
      --priority) shift; priority=${1:-} ;;
      --kind) shift; kind=${1:-} ;;
      --blocked-by) shift; blocked+=("${1:-}") ;;
      --owner) shift; owner=${1:-} ;;
      *) die "unknown option: $1" ;;
    esac
    shift
  done
  fm_ticket_key_valid "$project" || die "unsafe project name: $project"
  [ -n "$title" ] || die "a title is required"
  [ -z "$body_file" ] || { [ -f "$body_file" ] || die "--body-file is not a file: $body_file"; }
  [ -n "$key" ] || key="$project-$(slugify "$title")"
  fm_ticket_key_valid "$key" || die "unsafe ticket key: $key"

  mode=$("$SCRIPT_DIR/fm-project-mode.sh" "$project" 2>/dev/null | awk '{print $1}')
  if [ -z "$owner" ]; then
    ids=$(fm_ticket_registry_ids "$DATA")
    for id in $ids; do
      case ",$(secondmate_registry_field "$DATA/secondmates.md" "$id" projects 2>/dev/null | tr -d ' '),"  in
        *",$project,"*) matches+=("$id") ;;
      esac
    done
    case "${#matches[@]}" in
      0) owner=main ;;
      1) owner=${matches[0]} ;;
      *) die "project $project is listed by several secondmates (${matches[*]}); pick one with --owner" ;;
    esac
    [ "$mode" != local-only ] || owner=main
  else
    [ "$owner" = main ] || secondmate_registry_field "$DATA/secondmates.md" "$owner" home >/dev/null 2>&1 \
      || die "--owner $owner is not main or a registered secondmate"
    if [ "$owner" != main ] && [ "$mode" = local-only ]; then
      die "project $project is local-only; its work stays in this home"
    fi
  fi

  # Idempotent resume: the key may already exist, in this home or handed off.
  rc=0
  fm_ticket_locate "$DATA" "$key" || rc=$?
  if [ "$rc" -eq 2 ]; then die "ticket $key exists in more than one home ($FM_TICKET_CANDIDATES)"; fi
  if [ "$rc" -eq 0 ]; then
    local have shown
    if [ "$FM_TICKET_OWNER" = main ]; then
      have=$(show_field_plain "$key" title) || die "could not read ticket $key to compare its title; rerun"
    else
      shown=$(fm_ticket_run_in_mate "$DATA" "$FM_TICKET_OWNER" fm-tasks-axi.sh show "$key" </dev/null 2>/dev/null) \
        || die "could not read ticket $key in $FM_TICKET_OWNER to compare its title; rerun"
      have=$(shown_value "$(printf '%s\n' "$shown" | sed -n 's/^  title: //p' | head -1)")
    fi
    if [ "$have" != "$title" ]; then
      DIE_RC=2 die "ticket key $key is already taken by a different ticket owned by $(owner_label "$FM_TICKET_OWNER"); pass --key"
    fi
    if [ "$FM_TICKET_OWNER" = "$owner" ] || [ "$FM_TICKET_OWNER" != main ]; then
      printf 'key=%s\nowner=%s\nstatus=exists\n' "$key" "$(owner_label "$FM_TICKET_OWNER")"
      exit 0
    fi
  else
    local add_args=("$key" "$title" --repo "$project" --queue)
    [ -z "$priority" ] || add_args+=(--priority "$priority")
    [ -z "$kind" ] || add_args+=(--kind "$kind")
    [ -z "$body" ] || add_args+=(--body "$body")
    [ -z "$body_file" ] || add_args+=(--body-file "$body_file")
    for id in "${blocked[@]+"${blocked[@]}"}"; do add_args+=(--blocked-by "$id"); done
    "$SCRIPT_DIR/fm-tasks-axi.sh" add "${add_args[@]}" >/dev/null || die "could not file $key in this home's backlog"
  fi
  if [ "$owner" = main ]; then
    printf 'key=%s\nowner=%s\nstatus=filed\n' "$key" "$(home_label)"
    exit 0
  fi
  if "$SCRIPT_DIR/fm-backlog-handoff.sh" "$owner" "$key" >&2; then
    printf 'key=%s\nowner=%s\nstatus=handed-off\n' "$key" "$owner"
    exit 0
  fi
  printf 'key=%s\nowner=%s\nstatus=pending-handoff\ndetail=filed Queued in this home; rerun the same command to retry the handoff to %s\n' "$key" "$(home_label)" "$owner"
  exit 4
}

case "${1:-}" in
  owner) shift; cmd_owner "$@" ;;
  locate-local) shift; cmd_locate_local "$@" ;;
  apply) shift; cmd_apply "$@" ;;
  route) shift; cmd_route "$@" ;;
  edit) shift; cmd_edit "$@" ;;
  status) shift; cmd_status "$@" ;;
  retry) shift; cmd_retry "$@" ;;
  resume-pending) shift; cmd_resume_pending "$@" ;;
  new) shift; cmd_new "$@" ;;
  -h | --help) usage ;;
  *) usage >&2; exit 2 ;;
esac
