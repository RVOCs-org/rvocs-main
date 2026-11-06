#!/usr/bin/env bash
# action: clone - fetch the vendor repositories into the sibling directory
#
#   ./rvocs.sh --clone                       # all vendor repos
#   ./rvocs.sh --target therock --clone     # just one
#
# Cloning is explicit: no other action fetches a repository automatically.
# tt-host and tt-stack share rvocs-hcs-tenstorrent, so cloning both is done once.
#
# usage: bash scripts/actions/clone.sh [target ...]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

WANTED="${1:-$ALL_TARGETS}"
seen=""
for t in $WANTED; do
  case "$t" in
    rvocs)
      log "rvocs-main is the current repository; nothing to clone"
      continue ;;
    tt-host|tt-stack|therock) ;;
    *) die "clone does not support target: $t" ;;
  esac

  dir=$(repo_dir "$t" 2>/dev/null || true)
  case " $seen " in
    *" ${dir:-none} "*) log "$t: already handled in this run"; continue ;;
  esac

  out=$(clone_repo "$t") || die "clone failed: $t"
  seen="$seen $out"
  log "$t: $out"
done
