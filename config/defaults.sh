#!/usr/bin/env bash
# ============================================================================
# Machine-readable defaults (sourced by scripts/lib/common.sh; not executed directly).
# Command-line options take precedence; these values only describe the behaviour
# when nothing is chosen explicitly.
# ============================================================================

# ---- this repository ----
# VERSION is the single source of truth (also read by other scripts, e.g. for
# artifact naming); the literal is only a fallback when the file is missing.
RVOCS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RVOCS_VERSION="${RVOCS_VERSION:-$(tr -d '[:space:]' < "$RVOCS_ROOT/VERSION" 2>/dev/null || echo v1.0.1)}"
RVOCS_BASELINE="${RVOCS_BASELINE:-rvocs-2026.10}"   # full-stack baseline name (manifest.yaml)
DEFAULT_PROXY_MODE="${DEFAULT_PROXY_MODE:-auto}"     # cn | direct | auto

# ---- host disk watermark in GB (used by doctor) ----
# therock needs ~30 GB of sources and a 200 GB build tree; tt-stack needs a ~6 GB
# workdir plus ~15 GB of image layers; the tt-host bundle is under 1 GB.
# These are conservative values: one full pass plus some slack.
DISK_MIN_RISCV64="${DISK_MIN_RISCV64:-260}"
DISK_MIN_X86_64="${DISK_MIN_X86_64:-120}"

# ---- artifact naming (must match what the sub-repos build) ----
#   tt-stack    : rvocs-vllm-tt-<arch>:<tenstorrent VERSION>
#   therock     : rvocs-vllm-therock<rocm major.minor>-<gpu>-<arch>:<amd-the-rock VERSION>
#   tt-host: rvocs-tt-deps_<version>_<debarch>.tar.zst / .deb
# <arch> follows the OCI convention (amd64 / riscv64); <debarch> is the Debian
# name (amd64 / riscv64).
image_arch() {
  case "$1" in
    x86_64|amd64)   echo amd64 ;;
    riscv64)        echo riscv64 ;;
    *)              echo "$1" ;;
  esac
}
arch_deb() { image_arch "$1"; }

# Upstream reference image: --download pulls it, then retags to the local name
TT_UPSTREAM_BASE="ghcr.io/tenstorrent/tt-inference-server/vllm-tt-metal-src-dev"
TT_IMAGE_VERSION="${TT_IMAGE_VERSION:-0.22.0-v0.79.0-rc11-d84049e}"
tt_upstream_image_tag() { # tt_upstream_image_tag <arch>
  case "$1" in
    riscv64)         echo "$TT_UPSTREAM_BASE-ubuntu-26.04-riscv64:$TT_IMAGE_VERSION" ;;
    *)               echo "$TT_UPSTREAM_BASE-ubuntu-22.04-amd64:$TT_IMAGE_VERSION" ;;
  esac
}

tt_image_tag() { # tt_image_tag <arch> -> local build name
  local v
  v=$(repo_version tt-stack 2>/dev/null || echo v0.1.0)
  [ "$v" = unknown ] && v=v0.1.0
  printf 'rvocs-vllm-tt-%s:%s' "$(image_arch "$1")" "$v"
}

# ---- AMD / TheRock image (must match ../amd-the-rock/config/defaults.sh) ----
AMDG_ROCM_VERSION="${AMDG_ROCM_VERSION:-10.0.0}"
AMDG_GPU_ID="${AMDG_GPU_ID:-r9700}"

# effective ROCm version: whatever the amd-the-rock checkout pins, else the default
amdg_rocm_version_eff() {
  local d rv
  d=$(repo_dir therock 2>/dev/null || true)
  if [ -n "$d" ] && [ -f "$d/manifest.yaml" ]; then
    rv=$(sed -n 's/^  rocm_version: *\([^ #]*\).*/\1/p' "$d/manifest.yaml" | head -1)
    [ -n "$rv" ] && { printf '%s' "$rv"; return 0; }
  fi
  printf '%s' "$AMDG_ROCM_VERSION"
}

amdg_image_tag() { # amdg_image_tag <arch> -> rvocs-vllm-therock<major.minor>-<gpu>-<arch>:<version>
  local v ver
  v=$(amdg_rocm_version_eff)
  ver=$(repo_version therock 2>/dev/null || echo v0.1.0)
  [ "$ver" = unknown ] && ver=v0.1.0
  printf 'rvocs-vllm-therock%s-%s-%s:%s' \
    "$(printf '%s' "$v" | awk -F. '{print $1"."$2}')" \
    "$AMDG_GPU_ID" \
    "$(image_arch "$1")" \
    "$ver"
}

# ---- inference engine ----
# The engine is a dimension of a target, not a target of its own: it selects
# which serving stack is built or pulled. vLLM is implemented today; llama.cpp
# and SGLang are planned (see docs/INTRODUCTION.md).
RVOCS_ENGINE="${RVOCS_ENGINE:-vllm}"
RVOCS_SUPPORTED_ENGINES="${RVOCS_SUPPORTED_ENGINES:-vllm}"
RVOCS_PLANNED_ENGINES="${RVOCS_PLANNED_ENGINES:-llamacpp sglang}"

engine_supported() { # engine_supported <name>
  case " $RVOCS_SUPPORTED_ENGINES " in
    *" $1 "*) return 0 ;;
    *)        return 1 ;;
  esac
}

engine_planned() { # engine_planned <name>: known, but not implemented yet
  case " $RVOCS_PLANNED_ENGINES " in
    *" $1 "*) return 0 ;;
    *)        return 1 ;;
  esac
}

# ---- published artifacts ----
# Images are published to a public Huawei Cloud SWR namespace; --download pulls
# <RVOCS_REGISTRY>/<tag>, e.g. swr.cn-east-3.myhuaweicloud.com/cloud-mdgx/rvocs-vllm-tt-amd64:v0.1.0
RVOCS_REGISTRY="${RVOCS_REGISTRY:-swr.cn-east-3.myhuaweicloud.com/cloud-mdgx}"

# tt-host .deb files are published as GitHub Releases assets. RELEASES.list holds
# the exact names/versions; the URL is built as page + /download/<version>/<name>.
# Point the slug at a fork or an internal mirror when needed.
RVOCS_TT_HOST_REPO_SLUG="${RVOCS_TT_HOST_REPO_SLUG:-RVOCs-org/rvocs-hcs-tenstorrent}"
RVOCS_TT_HOST_RELEASES_PAGE="${RVOCS_TT_HOST_RELEASES_PAGE:-https://github.com/${RVOCS_TT_HOST_REPO_SLUG}/releases}"

# ---- deployment defaults (used by the internal deploy helper; --deploy is not
#      exposed yet, every value can be overridden) ----
TT_DEPLOY_MODEL="${TT_DEPLOY_MODEL:-Qwen3-8B}"
TT_DEPLOY_DEVICE="${TT_DEPLOY_DEVICE:-n300}"
TT_CACHE_VOLUME="${TT_CACHE_VOLUME:-volume_id_$TT_DEPLOY_MODEL}"
DEPLOY_PORT="${DEPLOY_PORT:-8000}"

AMDG_DEPLOY_MODEL="${AMDG_DEPLOY_MODEL:-Qwen3.5-9B}"
AMDG_MODELS_DIR="${AMDG_MODELS_DIR:-/models}"
AMDG_CONTAINER_NAME="${AMDG_CONTAINER_NAME:-rvocs-vllm}"
