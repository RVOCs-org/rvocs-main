#!/usr/bin/env bash
# action: build - build from source (image or host bundle)
#
# Argument translation (rvocs -> sub-repo):
#   --arch x86|riscv|arm   -> --arch x86_64|riscv64|aarch64
#   --proxy cn|direct|auto -> --proxy unchanged
#   --stage <s>            -> --stage unchanged (sub-repo default when omitted)
#   -- <args...>           -> appended unchanged (e.g. amd-the-rock --gpu / --jobs / --components)
#
# usage: bash scripts/actions/build.sh <target> [-- passthrough args]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

TARGET="${1:?usage: build.sh <target> [-- args]}"; shift || true
EXTRA=("$@")

dir=$(require_entry "$TARGET")
args=(--arch "$ARCH" --proxy "$PROXY_MODE")
[ -n "$STAGE" ] && args+=(--stage "$STAGE")

case "$TARGET" in
  tt-stack)
    log "building the Tenstorrent stack image from source (tt-metal + vLLM + plugin)"
    log "expected: about 2-4 hours on riscv64 with the bundled SFPI package, +90 min when it has to be built"
    log "output image: $(image_tag_for tt-stack "$ARCH")"
    ;;
  therock)
    log "building the ROCm/TheRock + Python stack image from source (gpu=$AMDG_GPU_ID)"
    log "expected: about 23 hours on riscv64 (TheRock ~17h + wheels ~5h + image ~50min)"
    log "output image: $(image_tag_for therock "$ARCH")"
    ;;
  tt-host)
    log "building the host dependency bundle (tt-deps, $ARCH)"
    log "artifacts: $(repo_part "$TARGET")/dist/rvocs-tt-deps_<version>_<debarch>.tar.zst and .deb"
    ;;
  *)
    die "build does not support $TARGET. $(target_hint "$TARGET" build)"
    ;;
esac

log "run: (cd $dir && bash $(repo_entry "$TARGET") $(quote_cmd "${args[@]}" "${EXTRA[@]}"))"
run_in "$dir" bash "$(repo_entry "$TARGET")" "${args[@]}" "${EXTRA[@]}"

case "$TARGET" in
  tt-stack|therock)
    log "build finished. start it with the docker run example in the target README (--deploy is not exposed yet)" ;;
  tt-host)
    log "build finished. install with: ./rvocs.sh --target tt-host --arch $ARCH --install" ;;
esac
