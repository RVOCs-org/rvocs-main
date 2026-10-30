#!/usr/bin/env bash
# action: download - fetch published artifacts (no build)
#
#   ./rvocs.sh --download rvocs-vllm-tt-amd64:v0.1.0
#       pulls <RVOCS_REGISTRY>/<tag>, then tags it with the short name
#   ./rvocs.sh --target tt-stack --arch riscv --download
#       pulls the image this target would build: rvocs-vllm-tt-riscv64:<version>
#   ./rvocs.sh --target therock --arch riscv --download
#       pulls rvocs-vllm-therock<rocm>-<gpu>-<arch>:<version>
#   ./rvocs.sh --target tt-host --arch riscv --download
#       downloads the newest rvocs-tt-deps_<version>_<debarch>.deb from the Gitee release
#
# usage: bash scripts/actions/download.sh <registry|target> [image-tag]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

TARGET="${1:-registry}"
REF="${2:-${DOWNLOAD_REF:-}}"
shift || true
shift || true
EXTRA=("$@")

case "$TARGET" in
  registry|auto)
    # an explicit tag is self-describing: no target/arch validation needed
    [ -n "$REF" ] || die "usage: ./rvocs.sh --download <name:tag>
       e.g. ./rvocs.sh --download rvocs-vllm-tt-amd64:v0.1.0"
    pull_published "$REF"
    log "done. local image: $REF"
    log "deploy with the matching target so the image name is picked up automatically"
    ;;

  tt-stack|therock)
    ref="${REF:-$(image_tag_for "$TARGET" "$ARCH")}"
    [ -n "$ref" ] || die "cannot derive an image name for $TARGET/$ARCH"
    pull_published "$ref"
    log "done. local image: $ref"
    ;;

  tt-host)
    debarch=$(arch_deb "$ARCH")
    url=$(tt_host_latest_deb "$debarch" || true)
    [ -n "$url" ] || die "no $debarch package found in $RVOCS_TT_HOST_RELEASES_PAGE
       (the API/page is unreachable, or the latest release has no such asset)"
    name=$(basename "$url")
    dest="$WORK_DIR/packages/$name"

    if [ "$DRY_RUN" = 1 ]; then
      printf '  [dry-run] curl -fL --retry 3 -o %s %s\n' "$dest" "$url"
      printf '  [dry-run] then: ./rvocs.sh --target tt-host --arch %s --install --yes\n' "$ARCH"
      exit 0
    fi

    require_cmd curl
    run mkdir -p "$WORK_DIR/packages"
    log "downloading: $name"
    log "  from $url"
    run curl -fL --retry 3 --connect-timeout 20 -o "$dest" "$url"
    log "downloaded: $dest ($(du -h "$dest" | awk '{print $1}'))"
    log "install with: ./rvocs.sh --target tt-host --arch $ARCH --install --yes"
    ;;

  *)
    die "download does not support target: $TARGET"
    ;;
esac
