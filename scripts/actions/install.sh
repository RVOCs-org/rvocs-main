#!/usr/bin/env bash
# action: install - install host dependencies (tt-kmd driver / tt-smi / tt-flash /
#         tt-topology / 1G hugepages / udev)
#
# Scope: tt-host only (other targets get host prerequisites from the distro
#        and the vendor driver packages).
#
# Flow:  newest .deb from the Gitee release (downloaded on demand) -> apt/dpkg
#        fallback: build the local bundle and run its ./install.sh (offline hosts,
#        or when the release has no asset for this architecture)
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
  # dry-run: show the download + install plan without touching the network
  if [ "$DRY_RUN" = 1 ]; then
    url=$(tt_host_latest_deb "$debarch" || true)
    if [ -n "$url" ]; then
      name=$(basename "$url")
      printf '  [dry-run] curl -fL --retry 3 -o %s/packages/%s %s\n' "$WORK_DIR" "$name" "$url"
      if have_cmd apt-get; then
        printf '  [dry-run] sudo apt-get install -y %s/packages/%s\n' "$WORK_DIR" "$name"
      else
        printf '  [dry-run] sudo dpkg -i %s/packages/%s\n' "$WORK_DIR" "$name"
      fi
      exit 0
    fi
  fi

  log "no local package for $debarch, fetching the latest release"
  if bash "$SCRIPT_DIR/download.sh" tt-host; then
    deb=$(tt_host_deb_local "$debarch")
  else
    warn "could not fetch a published package"
  fi
fi

if [ -n "$deb" ]; then
  log "package: $deb"
  if [ "$DRY_RUN" = 1 ]; then
    if have_cmd apt-get; then
      printf '  [dry-run] sudo apt-get install -y %s\n' "$deb"
    else
      printf '  [dry-run] sudo dpkg -i %s\n' "$deb"
    fi
    exit 0
  fi

  [ "$YES" = 1 ] || die "installation loads kernel modules and writes to /etc; re-run with --yes:
       ./rvocs.sh --target tt-host --arch $ARCH --install --yes"

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
  if [ "$DRY_RUN" = 1 ]; then
    printf '  [dry-run] (cd %s && bash %s --arch %s --proxy %s --dry-run)\n' "$dir" "$(repo_entry "$TARGET")" "$ARCH" "$PROXY_MODE"
    printf '  [dry-run] then install dist/rvocs-tt-deps_*_%s.deb (or the .tar.zst bundle)\n' "$debarch"
    exit 0
  fi
  log "no bundle for $ARCH yet, building it first (fetch -> patch -> wheels -> kmd -> bundle -> verify)"
  run_in "$dir" bash "$(repo_entry "$TARGET")" --arch "$ARCH" --proxy "$PROXY_MODE"
  bundle=$(find_bundle)
  [ -n "$bundle" ] || die "still no dist/rvocs-tt-deps_*_${debarch}.tar.zst after the build"
fi
log "bundle: $bundle"

if [ "$DRY_RUN" = 1 ]; then
  printf '  [dry-run] mkdir -p %s && tar -xf %s -C %s --strip-components=1\n' "$dest" "$bundle" "$dest"
  printf '  [dry-run] (cd %s && sudo ./install.sh %s)\n' "$dest" "${EXTRA[*]:-}"
  exit 0
fi

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
[ "$YES" = 1 ] || die "installation loads kernel modules and writes to /etc; re-run with --yes:
       ./rvocs.sh --target tt-host --arch $ARCH --install --yes"

log "running the installer (sudo)"
( cd "$dest" && sudo ./install.sh "${EXTRA[@]}" )
log "install finished. self-check: (cd $dest && ./verify.sh)"
