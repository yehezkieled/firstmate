#!/usr/bin/env bash
# fm-git-origin-lib.sh - the shared notion of "the same repository" across
# separate clones, with no source-time side effects.
#
# Treehouse keys one worktree pool by repository name plus a hash of the
# origin URL, so every home on this machine whose project clone has the same
# origin draws from one pool: a slot handed to a secondmate home may be a
# worktree of the root home's clone (see fm_treehouse_project_lock_path in
# fm-wake-lib.sh, which serializes that shared pool). Callers that must decide
# whether a pooled worktree belongs to a project compare this identity rather
# than git common dirs alone.

# Print the resolved origin identity of the repository containing <dir>, or
# fail when it has no origin. A local origin path is resolved to its physical
# path so two spellings of one bare repository agree.
fm_git_origin_identity() {  # <dir>
  local dir=$1 origin
  [ -d "$dir" ] || return 1
  origin=$(git -C "$dir" remote get-url origin 2>/dev/null || true)
  [ -n "$origin" ] || return 1
  case "$origin" in
    /*) [ ! -d "$origin" ] || origin=$(CDPATH='' cd -- "$origin" 2>/dev/null && pwd -P) || return 1 ;;
    *://*|*:* ) ;;
    *) [ ! -d "$dir/$origin" ] || origin=$(CDPATH='' cd -- "$dir/$origin" 2>/dev/null && pwd -P) || return 1 ;;
  esac
  printf '%s\n' "$origin"
}

# Succeed when both directories are in repositories that share a non-empty
# origin identity.
fm_git_same_origin() {  # <dir-a> <dir-b>
  local a b
  a=$(fm_git_origin_identity "$1") || return 1
  b=$(fm_git_origin_identity "$2") || return 1
  [ "$a" = "$b" ]
}
