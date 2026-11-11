#!/usr/bin/env bash
# action: download - fetch published artifacts listed in RELEASES.list
#
#   ./rvocs.sh --download rvocs-vllm-tt-amd64:v0.1.0   # one explicit image
#   ./rvocs.sh --target tt-stack --arch riscv --download
#   ./rvocs.sh --target therock --arch riscv --download
#   ./rvocs.sh --target tt-host --arch riscv --download
#
# RELEASES.list is grouped by target and host architecture: --download picks
# the first (newest) row of this target in the block matching --arch. Use
# --list-releases to see all of them.
#
# usage: bash scripts/actions/download.sh <registry|target> [image-tag]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

TARGET="${1:-registry}"
REF="${2:-${DOWNLOAD_REF:-}}"

case "$TARGET" in
  registry|auto)
    # an explicit tag is self-describing: no target/arch validation needed
    [ -n "$REF" ] || die "usage: ./rvocs.sh --download <name:tag>
       e.g. ./rvocs.sh --download rvocs-vllm-tt-amd64:v0.1.0"
    pull_published "$REF" "$(release_digest_of_artifact "$REF")"
    log "done. local image: $REF"
    ;;

  tt-stack|therock)
    ref="${REF:-$(release_artifact_for_arch "$TARGET" "$ARCH" || true)}"
    [ -n "$ref" ] || die "no published image for $TARGET/$ARCH in $RELEASES_FILE
       run: ./rvocs.sh --target $TARGET --list-releases"
    pull_published "$ref" "$(release_digest_for_arch "$TARGET" "$ARCH")"
    log "done. local image: $ref"
    ;;

  tt-host)
    if [ -n "$REF" ]; then
      name="$REF"
      ver=$(release_version_of_artifact tt-host "$name")
      dg=$(release_digest_of_artifact "$name")
    else
      IFS=$'	' read -r ver name dg < <(release_latest_for_arch tt-host "$ARCH") || true
    fi
    [ -n "$name" ] && [ -n "$ver" ] || die "no published .deb for tt-host/$ARCH in $RELEASES_FILE
       run: ./rvocs.sh --target tt-host --list-releases"
    # the .deb lives on github.com: honour --proxy cn / auto detection, the
    # same way the clone path does
    [ -n "${PROXY:-}" ] || resolve_proxy
    url=$(release_download_url "$ver" "$name")
    [ "${PROXY:-0}" = 1 ] && url=$(gh_url "$url")
    dest="$WORK_DIR/packages/$name"

    require_cmd curl
    run mkdir -p "$WORK_DIR/packages"
    log "downloading: $name (version $ver)"
    log "  from $url"
    run curl -fL --retry 3 --connect-timeout 20 -o "$dest" "$url"
    if [ -n "$dg" ]; then
      actual="sha256:$(sha256sum "$dest" | cut -d' ' -f1)"
      if [ "$actual" != "$dg" ]; then
        die "digest mismatch for $name
       expected: $dg
       actual  : $actual
       the file is kept at $dest for inspection; if the asset was republished
       on purpose, update RELEASES.list, otherwise do not use it"
      fi
      log "digest verified: $dg"
    else
      warn "no digest recorded for $name in $RELEASES_FILE: skipping verification"
    fi
    log "downloaded: $dest ($(du -h "$dest" | awk '{print $1}'))"
    log "install with: ./rvocs.sh --target tt-host --arch $ARCH --install"
    ;;

  *)
    die "download does not support target: $TARGET"
    ;;
esac
