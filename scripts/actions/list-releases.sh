#!/usr/bin/env bash
# action: list-releases - print the published artifacts from RELEASES.list
#
#   ./rvocs.sh --list-releases                  # all targets
#   ./rvocs.sh --target amd --list-releases    # one target (amd = therock)
#   ./rvocs.sh --target tenstorrent --list-releases
#
# Output is grouped by target (tt-host / tt-stack / therock) and newest first
# inside each target, mirroring the layout of RELEASES.list.
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

found=0
for t in $ALL_TARGETS; do
  [ "$t" = rvocs ] && continue
  if [ "$show_all" != 1 ]; then
    case " $WANTED " in *" $t "*) ;; *) continue ;; esac
  fi
  latest=$(release_latest_version "$t" || true)
  [ -n "$latest" ] || continue
  rows=$(release_rows | awk -v t="$t" '$1 == t')
  [ -n "$rows" ] || continue
  found=1

  printf '\033[1m%s\033[0m\n' "$t"
  {
    printf 'VERSION\tARTIFACT\tDIGEST\tNOTE\n'
    while IFS=$'\t' read -r _ ver art dg; do
      [ -n "$ver" ] || continue
      note=""
      if [ "$ver" = "$latest" ]; then note="latest"; fi
      printf '%s\t%s\t%s\t%s\n' "$ver" "$art" "${dg:--}" "$note"
    done <<< "$rows"
  } | render_tsv | sed 's/^/  /'
  echo
done

if [ "$found" != 1 ]; then
  warn "no published artifacts for: $WANTED"
  echo "  add a line at the top of the target + architecture block in $RELEASES_FILE"
  exit 1
fi

echo "Download the newest artifact for this host:"
echo "  ./rvocs.sh --target <target> --arch $(arch_short "$ARCH") --download"
echo "  ./rvocs.sh --download <full docker tag>      # pull one explicit image"
