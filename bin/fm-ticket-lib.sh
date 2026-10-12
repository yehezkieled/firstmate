#!/usr/bin/env bash
# shellcheck disable=SC2034 # result fields are output globals for sourcing callers.
# fm-ticket-lib.sh - the one owner of "which home owns this ticket".
#
# A ticket (a backlog item) has exactly one owning home: the primary home or one
# registered secondmate home. Ownership moves only by handoff
# (bin/fm-backlog-handoff.sh); everything else reaches the owner as a routed
# request. This library answers the ownership question for every caller that has
# to route by it - bin/fm-ticket.sh (owner lookup, routed edit, one-step new
# ticket) and bin/fm-captain-hold.sh (owner-aware keyed answers and reconcile) -
# so that routing never re-implements a second lookup.
#
# The lookup reads section headings and item header lines of each home's
# markdown backlog and never an item body, the same boundary
# bin/fm-backlog-handoff.sh keeps; the item format itself stays owned by
# tasks-axi. A local mate is read from its validated home directory. A remote
# mate is asked through bin/fm-on.sh, and a home that cannot be read is named in
# FM_TICKET_UNREADABLE and never guessed: absence in a readable home is a fact,
# absence in an unreadable one is "unknown".
#
# Callers set SCRIPT_DIR (this checkout's bin/) before sourcing and pass the
# active data directory. Sourcing has no side effects.

# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)/fm-secondmate-registry-lib.sh"

FM_TICKET_OWNER=
FM_TICKET_SECTION=
FM_TICKET_HOME=
FM_TICKET_REMOTE=0
FM_TICKET_UNREADABLE=
FM_TICKET_CANDIDATES=
FM_TICKET_ERROR=

# Section (## In flight / ## Queued / ## Done) of the item whose header id is
# <key>; 1 when no header carries that id, 2 when the backlog cannot be read
# (absence there is unknown, never a fact).
fm_backlog_key_section() { # <backlog-file> <key>
  local file=$1 key=$2 rc=0
  [ -f "$file" ] || return 1
  [ -r "$file" ] || return 2
  awk -v key="$key" '
    BEGIN { section = "## Queued" }
    /^##[[:space:]]+/ {
      section = $0
      sub(/^##[[:space:]]+/, "## ", section)
      sub(/[[:space:]]+$/, "", section)
      next
    }
    /^- \[[ x]\] / {
      rest = $0
      sub(/^- \[[ x]\] +/, "", rest)
      id = rest
      sub(/[ \t].*/, "", id)
      if (id == key) { print section; found = 1; exit }
    }
    END { exit found ? 0 : 1 }
  ' "$file" || rc=$?
  [ "$rc" -le 1 ] || return 2
  return "$rc"
}

fm_ticket_key_valid() { # <key>
  case "$1" in '' | *[!A-Za-z0-9._-]*) return 1 ;; esac
  [ "${#1}" -le 128 ]
}

# Registered secondmate ids, one per line.
fm_ticket_registry_ids() { # <data-dir>
  local reg=$1/secondmates.md line id
  [ -f "$reg" ] && [ ! -L "$reg" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in "- "*) ;; *) continue ;; esac
    id=${line#- }
    id=${id%% *}
    case "$id" in '' | *[!A-Za-z0-9._-]*) continue ;; esac
    printf '%s\n' "$id"
  done < "$reg"
}

# The seeded home directory of local mate <id>, printed. Proves the identity
# marker names the id and that the directory is a firstmate home, so a stale
# registry path can never route a request into an unrelated directory.
fm_ticket_local_home() { # <data-dir> <id>
  local reg=$1/secondmates.md home marker
  FM_TICKET_ERROR=
  home=$(secondmate_registry_field "$reg" "$2" home 2>/dev/null || true)
  case "$home" in /*) ;; *)
    FM_TICKET_ERROR="secondmate $2 has no usable home in the registry"
    return 1
    ;;
  esac
  [ -d "$home" ] || { FM_TICKET_ERROR="secondmate $2 home is not a directory: $home"; return 1; }
  home=$(cd "$home" && pwd -P)
  marker="$home/.fm-secondmate-home"
  if [ ! -f "$marker" ] || [ -L "$marker" ] || [ "$(cat "$marker" 2>/dev/null || true)" != "$2" ]; then
    FM_TICKET_ERROR="secondmate $2 home is not a seeded home marked for it: $home"
    return 1
  fi
  [ -f "$home/AGENTS.md" ] && [ -d "$home/bin" ] || {
    FM_TICKET_ERROR="secondmate $2 home is not a firstmate home: $home"
    return 1
  }
  printf '%s\n' "$home"
}

fm_ticket_registry_remote() { # <data-dir> <id>
  [ "$(secondmate_registry_field "$1/secondmates.md" "$2" remote 2>/dev/null || true)" = 1 ]
}

# Section of <key> in registered mate <id>'s backlog. Exit 0 found (section
# printed), 1 provably absent, 2 the home could not be read.
fm_ticket_probe_mate() { # <data-dir> <id> <key>
  local data=$1 id=$2 key=$3 home section rc=0 out
  if fm_ticket_registry_remote "$data" "$id"; then
    out=$("$SCRIPT_DIR/fm-on.sh" "$id" fm-ticket.sh locate-local "$key" </dev/null 2>/dev/null) || rc=$?
    case "$rc" in
      0) printf '%s\n' "$out" | head -1; return 0 ;;
      # fm-on.sh dies with 1 too, so absence must be the remote script's own
      # explicit answer, never just an exit status.
      1) [ "$out" = fm-ticket-absent ] && return 1; return 2 ;;
      *) return 2 ;;
    esac
  fi
  home=$(fm_ticket_local_home "$data" "$id") || return 2
  if [ ! -f "$home/data/backlog.md" ]; then
    return 1
  fi
  rc=0
  section=$(fm_backlog_key_section "$home/data/backlog.md" "$key") || rc=$?
  case "$rc" in
    0) printf '%s\n' "$section"; return 0 ;;
    1) return 1 ;;
    *) return 2 ;;
  esac
}

# Locate ticket <key>: the primary backlog first (unless --mates-only), then
# every registered mate. Sets FM_TICKET_OWNER (main, a mate id, ambiguous, or
# empty), FM_TICKET_SECTION, FM_TICKET_HOME (local owner's home), FM_TICKET_REMOTE,
# FM_TICKET_CANDIDATES (every owner that carries the key), and
# FM_TICKET_UNREADABLE (mates whose backlog could not be read). Exit 0 owner
# found, 1 no readable home carries it, 2 more than one home carries it.
fm_ticket_locate() { # <data-dir> <key> [--mates-only]
  local data=$1 key=$2 mates_only=0 id section rc owners=()
  [ "${3:-}" != --mates-only ] || mates_only=1
  FM_TICKET_OWNER=
  FM_TICKET_SECTION=
  FM_TICKET_HOME=
  FM_TICKET_REMOTE=0
  FM_TICKET_UNREADABLE=
  FM_TICKET_CANDIDATES=
  fm_ticket_key_valid "$key" || { FM_TICKET_ERROR="unsafe ticket key: $key"; return 1; }
  if [ "$mates_only" -eq 0 ]; then
    rc=0
    section=$(fm_backlog_key_section "$data/backlog.md" "$key") || rc=$?
    case "$rc" in
      0) owners+=(main); FM_TICKET_SECTION=$section ;;
      1) : ;;
      *) FM_TICKET_UNREADABLE=main ;;
    esac
  fi
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    rc=0
    section=$(fm_ticket_probe_mate "$data" "$id" "$key") || rc=$?
    case "$rc" in
      0)
        owners+=("$id")
        [ -n "$FM_TICKET_SECTION" ] || FM_TICKET_SECTION=$section
        ;;
      1) : ;;
      *) FM_TICKET_UNREADABLE="${FM_TICKET_UNREADABLE:+$FM_TICKET_UNREADABLE }$id" ;;
    esac
  done < <(fm_ticket_registry_ids "$data")
  FM_TICKET_CANDIDATES="${owners[*]:-}"
  case "${#owners[@]}" in
    0) return 1 ;;
    1) ;;
    *) FM_TICKET_OWNER=ambiguous; return 2 ;;
  esac
  FM_TICKET_OWNER=${owners[0]}
  if [ "$FM_TICKET_OWNER" != main ]; then
    if fm_ticket_registry_remote "$data" "$FM_TICKET_OWNER"; then
      FM_TICKET_REMOTE=1
    else
      FM_TICKET_HOME=$(fm_ticket_local_home "$data" "$FM_TICKET_OWNER") || return 1
    fi
  fi
  return 0
}

# Run a Firstmate command in mate <id>'s home, stdin passed through. A local mate
# runs this checkout's own script with FM_HOME pointed at the mate and every
# path override cleared, so the command resolves the mate's data and state; a
# remote mate runs it through bin/fm-on.sh. The command's exit status is
# returned (255 from a remote means unavailable transport or unknown completion).
fm_ticket_run_in_mate() { # <data-dir> <id> <script-basename> [args...]
  local data=$1 id=$2 script=$3 home
  shift 3
  if fm_ticket_registry_remote "$data" "$id"; then
    "$SCRIPT_DIR/fm-on.sh" --stdin "$id" "$script" "$@"
    return $?
  fi
  home=$(fm_ticket_local_home "$data" "$id") || {
    printf 'error: %s\n' "$FM_TICKET_ERROR" >&2
    return 2
  }
  env -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE \
    -u FM_PROJECTS_OVERRIDE -u FM_ROOT_OVERRIDE -u FM_PENDING_REPLY_DIR_OVERRIDE \
    FM_HOME="$home" "$SCRIPT_DIR/$script" "$@"
}
