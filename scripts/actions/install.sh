#!/usr/bin/env bash
# action: install - install host dependencies (tt-kmd driver / tt-smi / tt-flash /
#         tt-topology / 1G hugepages / udev)
#
# Scope: tt-host only.
#
# Flow: newest .deb from RELEASES.list (downloaded on demand) -> apt/dpkg
#       fallback: build the local bundle and run its ./install.sh
#
# usage: bash scripts/actions/install.sh tt-host [-- <install.sh args>]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

TARGET="${1:?usage: install.sh <target> [-- args]}"; shift || true
EXTRA=("$@")

[ "$TARGET" = tt-host ] || die "install only supports tt-host ($(target_hint "$TARGET" install))"

debarch=$(arch_deb "$ARCH")

# ---------------------------------------------------------------- published .deb
deb=$(tt_host_deb_local "$debarch")
if [ -z "$deb" ]; then
  log "no local package for $debarch, fetching the newest published one"
  if bash "$SCRIPT_DIR/download.sh" tt-host; then
    deb=$(tt_host_deb_local "$debarch")
  else
    warn "could not fetch a published package"
  fi
fi

if [ -n "$deb" ]; then
  log "package: $deb"
  if have_cmd apt-get; then
    log "installing with apt-get (sudo)"
    run sudo apt-get install -y "$deb"
  else
    log "installing with dpkg (sudo)"
    run sudo dpkg -i "$deb"
  fi
  log "install finished. self-check: dpkg -s rvocs-tt-deps | head -3; ls /opt/tt-deps"
  exit 0
fi

# ---------------------------------------------------------------- local bundle fallback
warn "falling back to a local build (no published package available for $debarch)"
dir=$(require_entry "$TARGET")
dest="$WORK_DIR/rvocs-tt-deps-$debarch"

find_bundle() {
  ls -1 "$dir/$(repo_part "$TARGET")/dist"/rvocs-tt-deps_*.tar.zst 2>/dev/null | grep -- "_${debarch}.tar.zst$" | tail -n 1 || true
}

bundle=$(find_bundle)
if [ -z "$bundle" ]; then
  log "no bundle for $ARCH yet, building it first (fetch -> patch -> wheels -> kmd -> bundle -> verify)"
  run_in "$dir" bash "$(repo_entry "$TARGET")" --arch "$ARCH" --proxy "$PROXY_MODE"
  bundle=$(find_bundle)
  [ -n "$bundle" ] || die "still no dist/rvocs-tt-deps_*_${debarch}.tar.zst after the build"
fi
log "bundle: $bundle"

require_cmd tar
run mkdir -p "$dest"
log "unpacking to $dest"
if tar --zstd -tf "$bundle" >/dev/null 2>&1; then
  tar --zstd -xf "$bundle" -C "$dest" --strip-components=1
elif have_cmd zstd; then
  zstd -dc "$bundle" | tar -xf - -C "$dest" --strip-components=1
else
  die "unpacking $bundle requires tar --zstd or the zstd command"
fi

[ -x "$dest/install.sh" ] || die "$dest/install.sh is missing or not executable (unexpected bundle layout?)"
log "running the installer (sudo)"
( cd "$dest" && sudo ./install.sh "${EXTRA[@]}" )
log "install finished. self-check: (cd $dest && ./verify.sh)"
