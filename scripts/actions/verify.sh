#!/usr/bin/env bash
# action: verify - acceptance checks
#
#   tenstorrent / therock : the sub-repo --stage verify (in-image smoke: driver,
#                           runtime, imports, entry points)
#   tt-host          : run the bundle verify.sh when unpacked, otherwise the
#                           static self-check of the bundle
#
# usage: bash scripts/actions/verify.sh <target> [-- passthrough args]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

TARGET="${1:?usage: verify.sh <target> [-- args]}"; shift || true
EXTRA=("$@")

dir=$(require_entry "$TARGET")

case "$TARGET" in
  tt-stack|therock)
    tag=$(image_tag_for "$TARGET" "$ARCH")
    if ! image_exists "$tag" && [ "$DRY_RUN" != 1 ]; then
      die "no local image $tag.
       build: ./rvocs.sh --target $TARGET --arch $ARCH --build
       or pull: ./rvocs.sh --target $TARGET --arch $ARCH --download"
    fi
    args=(--arch "$ARCH" --proxy "$PROXY_MODE" --stage verify)
    [ "$DRY_RUN" = 1 ] && args+=(--dry-run)
    if [ "$TARGET" = therock ]; then
      args+=(--gpu "$AMDG_GPU_ID")
    fi
    log "verifying image: $tag"
    log "run: (cd $dir && bash $(repo_entry "$TARGET") $(quote_cmd "${args[@]}" "${EXTRA[@]}"))"
    run_in "$dir" bash "$(repo_entry "$TARGET")" "${args[@]}" "${EXTRA[@]}"
    ;;

  tt-host)
    installed="$WORK_DIR/rvocs-tt-deps-$(arch_deb "$ARCH")"
    if [ -x "$installed/verify.sh" ]; then
      log "host self-check (unpacked bundle): $installed/verify.sh"
      run_in "$installed" ./verify.sh "${EXTRA[@]}"
    else
      log "no unpacked bundle found; running the static bundle check (build.sh --stage verify)"
      args=(--arch "$ARCH" --proxy "$PROXY_MODE" --stage verify)
      [ "$DRY_RUN" = 1 ] && args+=(--dry-run)
      run_in "$dir" bash "$(repo_entry "$TARGET")" "${args[@]}" "${EXTRA[@]}"
    fi
    ;;

  *)
    die "verify does not support $TARGET. $(target_hint "$TARGET" verify)"
    ;;
esac
