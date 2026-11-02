#!/usr/bin/env bash
# RVOCs unified entry point - one command to drive three sibling repositories
# (host dependencies / device-stack images / deployment).
#
# Usage:
#   ./rvocs.sh [action] [--target TARGET] [--arch ARCH] [options] [-- passthrough args]
#
# Actions (mutually exclusive, pick one):
#   --version         print the rvocs-main version; with --target, print that
#                     target's version plus its upstream component pins
#   --status          print repo status, artifacts, images and devices
#   --doctor          environment self-check (first step of Quickstart): host conditions and
#                     known quirks, followed by the commands to run next
#   --bom             print the full-stack version matrix (BOM)
#   --install         install host dependencies (tt-kmd driver / tt-smi / 1G hugepages / udev)
#   --download [tag]  pull a published image (<RVOCS_REGISTRY>/<tag>) or, with
#                     --target tt-host, the newest .deb from the Gitee release
#   --build           build from source (image or host bundle)
#   --verify          acceptance checks (in-image smoke / bundle static checks)
#   --deploy          print the container command; with --yes, run it
#   --list-targets    print the target/action capability matrix
#
# Targets (--target; multiple separated by / or ,):
#   tt-host   host dependencies (tt-kmd / tt-smi / tt-flash / tt-topology / hugepages)
#   tt-stack       TT-Metal + vLLM inference image (device: Tenstorrent cards)
#   therock        ROCm/TheRock + vLLM inference image (device: AMD GPUs)
#   rvocs          this repository itself (version/status/doctor/bom only)
#   all            all of the above
#
# Options:
#   --engine vllm               inference engine (default vllm; llamacpp / sglang are
#                               planned and rejected until implemented)
#   --arch x86|riscv|arm|host   target arch (default host; normalized to x86_64/riscv64/aarch64)
#   --stage <stage>             forwarded to the sub-repo --stage (e.g. image / "fetch workdir" / prep)
#   --proxy cn|direct|auto      network mode (default auto, probes github.com)
#   --workdir <dir>             work directory (default ./work)
#   --no-clone                  do not auto-clone sub-repos (offline or existing copies)
#   --dry-run                   only print the commands that would run
#   --sync                      with --bom: rewrite the bom versions from the sub-repos
#   --yes, -y                   allow actions with side effects (deploy / sudo in install)
#   -h, --help                  show this help
#   -- <args...>                pass through to the sub-repo script
#
# Examples:
#   ./rvocs.sh --version
#   ./rvocs.sh --target tt-host --arch riscv --install
#   ./rvocs.sh --target tt-stack --arch riscv --download
#   ./rvocs.sh --target tt-stack --arch riscv --build
#   ./rvocs.sh --target tt-stack/therock/tt-host --version
#   ./rvocs.sh --target all --doctor
#   ./rvocs.sh --target therock --arch x86 --build -- --gpu r9700 --jobs 32
#
# Notes: sub-repos are reused as sibling directories (default ../rvocs-hcs-tenstorrent,
#        ../rvocs-hcs-amd). When missing they are cloned on demand by the action that needs them
#        (single branch, master). Use RVOCS_SIBLINGS_DIR / RVOCS_TT_HOST_DIR / RVOCS_TT_STACK_DIR /
#        RVOCS_THEROCK_DIR to relocate, --no-clone to disable fetching. This script only translates
#        arguments and chains stages; it never reimplements build logic. See docs/CLI.md.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/scripts/lib/common.sh"

_usage_text() { awk 'NR>1 && /^#/ { sub(/^# ?/,""); print; next } NR>1 { exit }' "$0"; }
usage() { _usage_text; exit 0; }

ACTION=""
TARGETS_RAW=""
ARCH_RAW=""
EXTRA=()

while [ $# -gt 0 ]; do
  case "$1" in
    --target)        TARGETS_RAW="${2:?--target requires an argument}"; shift 2 ;;
    --arch)          ARCH_RAW="${2:?--arch requires an argument}"; shift 2 ;;
    --engine)        RVOCS_ENGINE_RAW="${2:?--engine requires an argument}"; shift 2 ;;
    --stage)         STAGE="${2:?--stage requires an argument}"; shift 2 ;;
    --proxy)         PROXY_MODE="${2:?--proxy requires an argument}"; shift 2 ;;
    --workdir)       WORK_DIR="${2:?--workdir requires an argument}"; shift 2; LOG_DIR="$WORK_DIR/logs" ;;
    --no-clone)      RVOCS_NO_CLONE=1; shift ;;
    --dry-run)       DRY_RUN=1; shift ;;
    --sync)          BOM_SYNC=1; shift ;;
    --yes|-y)        YES=1; shift ;;
    --list-targets)  ACTION=list-targets; shift ;;
    --download)
                     [ -n "$ACTION" ] && die "only one action allowed (already --$ACTION, got $1)"
                     ACTION=download; shift
                     # optional positional tag: --download rvocs-vllm-tt-amd64:v0.1.0
                     if [ $# -gt 0 ] && [ "${1#-}" = "$1" ]; then DOWNLOAD_REF="$1"; shift; fi ;;
    --version|--status|--doctor|--bom|--install|--build|--verify|--deploy)
                     [ -n "$ACTION" ] && die "only one action allowed (already --$ACTION, got $1)"
                     ACTION="${1#--}"; shift ;;
    -h|--help)       usage ;;
    --)              shift; EXTRA=("$@"); break ;;
    *)               die "unknown argument: $1 (see --help)" ;;
  esac
done

[ -n "$ACTION" ] || { _usage_text >&2; exit 1; }

# ---------------------------------------------------------------- arch normalization
ARCH=$(normalize_arch "${ARCH_RAW:-${ARCH:-host}}")
arch_ok "$ARCH" || die "unsupported arch: $ARCH (expected x86|riscv|arm|host)"

# ---------------------------------------------------------------- engine
RVOCS_ENGINE=$(printf '%s' "${RVOCS_ENGINE_RAW:-${RVOCS_ENGINE:-vllm}}" | tr '[:upper:]' '[:lower:]')
export RVOCS_ENGINE
if ! engine_supported "$RVOCS_ENGINE"; then
  if engine_planned "$RVOCS_ENGINE"; then
    die "engine '$RVOCS_ENGINE' is on the roadmap but not implemented yet
       supported now: $RVOCS_SUPPORTED_ENGINES
       planned:       $RVOCS_PLANNED_ENGINES"
  fi
  die "unknown engine: $RVOCS_ENGINE (supported: $RVOCS_SUPPORTED_ENGINES; planned: $RVOCS_PLANNED_ENGINES)"
fi

# ---------------------------------------------------------------- target parsing
TARGETS=""
add_target() {
  local t="$1" norm
  norm=$(normalize_target "$t") || die "unknown target: $t (see --list-targets)"
  case " $TARGETS " in *" $norm "*) return 0 ;; esac
  TARGETS="${TARGETS:+$TARGETS }$norm"
}

if [ -n "$TARGETS_RAW" ]; then
  case "$TARGETS_RAW" in
    all) for t in $ALL_TARGETS; do add_target "$t"; done ;;
    *)
      # accept both "a/b/c" and "a,b,c"
      for t in $(printf '%s' "$TARGETS_RAW" | tr '/,' '  '); do add_target "$t"; done ;;
  esac
fi

# read-only actions default to all targets; actions with side effects must be explicit
case "$ACTION" in
  version)
    # bare --version answers "what version is rvocs-main"; targets must be asked for
    [ -n "$TARGETS" ] || TARGETS="rvocs" ;;
  status|doctor|bom|list-targets)
    [ -n "$TARGETS" ] || TARGETS="$ALL_TARGETS" ;;
  download)
    # an explicit tag needs no target; otherwise require one (image name depends on it)
    if [ -n "${DOWNLOAD_REF:-}" ] && [ -z "$TARGETS" ]; then TARGETS="registry"; fi
    [ -n "$TARGETS" ] || die "download requires a tag or --target:
       ./rvocs.sh --download rvocs-vllm-tt-amd64:v0.1.0
       ./rvocs.sh --target tt-stack --arch riscv --download" ;;
  *)
    [ -n "$TARGETS" ] || die "$ACTION requires an explicit --target (choices: $REPO_IDS all)
       e.g. ./rvocs.sh --target tt-stack --arch riscv --$ACTION" ;;
esac

read -r -a TARGET_ARR <<< "$TARGETS"
# only actions that actually call a sub-repo script need the repo in place (cloned if missing):
#   install/build/verify need scripts/build.sh; download decides per target (docker pull needs none);
#   deploy only needs the image name and deploy settings; read-only actions never hit the network.
case "$ACTION" in
  build|verify) NEEDS_ENTRY=1 ;;
  *)            NEEDS_ENTRY=0 ;;
esac

# ---------------------------------------------------------------- pre-flight checks
# aggregate read-only actions treat targets as a filter, so not every target must support them
case "$ACTION" in
  version|status|doctor|bom|list-targets) AGGREGATE=1 ;;
  *)                                      AGGREGATE=0 ;;
esac

if [ "$ACTION" != list-targets ] && [ -z "${DOWNLOAD_REF:-}" ]; then
  for t in "${TARGET_ARR[@]}"; do
    [ "$AGGREGATE" = 1 ] || assert_action_supported "$t" "$ACTION"
    [ "$t" = rvocs ] || assert_arch_supported "$t" "$ARCH"
  done
fi

mkdir -p "$WORK_DIR" "$LOG_DIR"
# network mode must be settled before any sub-repo clone happens
case "$ACTION" in
  # download talks to a registry or the Gitee release, never to github.com
  list-targets|version|status|bom|download) : ;;
  *) resolve_proxy ;;
esac

# action scripts are separate processes: export the facts they need
# TARGETS holds the orchestration target (tt-host / tt-stack) and must not leak:
# the vendor build scripts read a same-named variable as their Ubuntu release
# list (use UBUNTU_TARGETS for that).
export ARCH PROXY_MODE PROXY DRY_RUN YES STAGE WORK_DIR LOG_DIR SIBLINGS_DIR
export -n TARGETS 2>/dev/null || true   # keep the value in this shell, drop the export attribute
export RVOCS_SIBLINGS_DIR="$SIBLINGS_DIR"
export BOM_SYNC="${BOM_SYNC:-0}"
export RVOCS_NO_CLONE="${RVOCS_NO_CLONE:-0}"
export DOWNLOAD_REF="${DOWNLOAD_REF:-}"

if [ "$NEEDS_ENTRY" = 1 ] && [ -z "${DOWNLOAD_REF:-}" ]; then
  for t in "${TARGET_ARR[@]}"; do require_entry "$t" >/dev/null; done
  # source builds / install / verify rely on the porting layer; download and deploy do not
  case "$ACTION" in
    build|verify) for t in "${TARGET_ARR[@]}"; do check_porting_branch "$t" "$ARCH"; done ;;
  esac
fi

# ---------------------------------------------------------------- plan banner
banner() {
  echo "============================================================"
  echo " RVOCs | orchestration layer ${RVOCS_VERSION}  .  baseline ${RVOCS_BASELINE}"
  echo "============================================================"
  printf '  %-12s: %s\n' "action" "$ACTION"
  printf '  %-12s: %s\n' "targets" "${TARGET_ARR[*]}"
  if [ -n "${DOWNLOAD_REF:-}" ]; then
    printf '  %-12s: %s\n' "image" "${RVOCS_REGISTRY%/}/${DOWNLOAD_REF}"
  fi
  printf '  %-12s: %s\n' "arch" "$ARCH"
  if [ -n "${RVOCS_ENGINE_RAW:-}" ]; then
    printf '  %-12s: %s\n' "engine" "$RVOCS_ENGINE"
  fi
  if [ -n "$PROXY" ]; then
    printf '  %-12s: %s (%s)\n' "network" "$PROXY_MODE" \
      "$([ "$PROXY" = 1 ] && echo 'mirrors: gh-proxy + Tsinghua' || echo 'direct')"
  fi
  printf '  %-12s: %s\n' "siblings" "$SIBLINGS_DIR"
  printf '  %-12s: %s\n' "workdir" "$WORK_DIR"
  [ -n "$STAGE" ] && printf '  %-12s: %s\n' "stage" "$STAGE"
  [ "$DRY_RUN" = 1 ] && printf '  %-12s: %s\n' "mode" "dry-run (no changes)"
  [ "$YES" = 1 ] && printf '  %-12s: %s\n' "confirm" "yes (side effects allowed)"
  [ ${#EXTRA[@]} -gt 0 ] && printf '  %-12s: %s\n' "passthrough" "${EXTRA[*]}"
  for t in "${TARGET_ARR[@]}"; do
    if [ "$t" = rvocs ] || [ "$t" = registry ]; then continue; fi
    if d=$(repo_dir "$t" 2>/dev/null); then
      _br=$(repo_branch "$t"); _hd=$(repo_head "$t")
      printf '  %-13s: %s (%s @ %s)\n' "$t" "$d" "${_br:-not a git repo}" "${_hd:--}"
    else
      printf '  %-13s: \033[1;33mmissing\033[0m (will be fetched: %s)\n' "$t" \
        "$(repo_url "$t" 2>/dev/null || echo 'no URL configured')"
    fi
  done
  echo "============================================================"
}
[ "$ACTION" = list-targets ] || banner

# ---------------------------------------------------------------- execution
print_matrix() {
  {
    printf 'TARGET\tARCH\tACTIONS\n'
    for t in $ALL_TARGETS; do
      printf '%s\t%s\t%s\n' "$t" "$(target_archs "$t")" "$(target_actions "$t")"
    done
  } | render_tsv

  echo
  echo "Targets (--arch accepts the short forms x86|riscv|arm|host):"
  for t in $ALL_TARGETS; do
    printf '  %-13s %s\n' "$t" "$(repo_label "$t")"
  done
}

run_aggregate() { # read-only actions: one call with all targets
  local script="$SCRIPT_DIR/scripts/actions/$ACTION.sh" logf="$LOG_DIR/rvocs.log"
  [ -f "$script" ] || die "missing action script: $script"
  if bash "$script" "$TARGETS" 2>&1 | tee -a "$logf"; then
    return 0
  fi
  die "action failed: $ACTION (log: $logf)"
}

run_per_target() {
  local t="$1" script="$SCRIPT_DIR/scripts/actions/$ACTION.sh" logf="$LOG_DIR/build.log"
  [ -f "$script" ] || die "missing action script: $script"
  echo
  log "===== $t ($(repo_label "$t")) ====="
  if bash "$script" "$t" "${EXTRA[@]}" 2>&1 | tee -a "$logf"; then
    log "done: $t"
  else
    die "failed: $t --$ACTION (log: $logf)"
  fi
}

case "$ACTION" in
  list-targets) print_matrix ;;
  version|status|doctor|bom) run_aggregate ;;
  download)
    if [ -n "${DOWNLOAD_REF:-}" ]; then
      echo
      log "===== download ${DOWNLOAD_REF} ====="
      if bash "$SCRIPT_DIR/scripts/actions/download.sh" registry "$DOWNLOAD_REF" 2>&1 | tee -a "$LOG_DIR/build.log"; then
        log "done: $DOWNLOAD_REF"
      else
        die "failed: --download $DOWNLOAD_REF (log: $LOG_DIR/build.log)"
      fi
      echo
      log "all done. action: download  image: $DOWNLOAD_REF"
    else
      for t in "${TARGET_ARR[@]}"; do run_per_target "$t"; done
      echo
      log "all done. action: $ACTION  targets: ${TARGET_ARR[*]}"
    fi
    ;;
  *)
    for t in "${TARGET_ARR[@]}"; do run_per_target "$t"; done
    echo
    log "all done. action: $ACTION  targets: ${TARGET_ARR[*]}"
    ;;
esac
