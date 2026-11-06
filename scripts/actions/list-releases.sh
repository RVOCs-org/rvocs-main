#!/usr/bin/env bash
# action: list-releases - print the published artifacts from RELEASES.list
#
#   ./rvocs.sh --list-releases                  # all targets
#   ./rvocs.sh --target amd --list-releases    # one target (amd = therock)
#   ./rvocs.sh --target tenstorrent --list-releases
#
# usage: bash scripts/actions/list-releases.sh [target ...]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

WANTED="${1:-$ALL_TARGETS}"
show_all=0
case " $WANTED " in
  *" all "*|*" rvocs "*) show_all=1 ;;
esac

[ -f "$RELEASES_FILE" ] || die "release list not found: $RELEASES_FILE"

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

{
  printf 'TARGET\tVERSION\tARTIFACT\tNOTE\n'
  for t in $ALL_TARGETS; do
    [ "$t" = rvocs ] && continue
    if [ "$show_all" != 1 ]; then
      case " $WANTED " in *" $t "*) ;; *) continue ;; esac
    fi
    latest=$(release_latest_version "$t" || true)
    [ -n "$latest" ] || continue
    while IFS=$'\t' read -r tt ver art; do
      [ "$tt" = "$t" ] || continue
      note=""
      [ "$ver" = "$latest" ] && note="latest"
      printf '%s\t%s\t%s\t%s\n' "$tt" "$ver" "$art" "$note"
    done < <(release_rows)
  done
} > "$tmp"

if [ "$(wc -l < "$tmp")" -le 1 ]; then
  warn "no published artifacts for: $WANTED"
  echo "  add one line per artifact to $RELEASES_FILE (newest first)"
  exit 1
fi

render_tsv < "$tmp"
echo
echo "Download the newest artifact for this host:"
echo "  ./rvocs.sh --target <target> --arch $(arch_short "$ARCH") --download"
echo "  ./rvocs.sh --download <full docker tag>      # pull one explicit image"
