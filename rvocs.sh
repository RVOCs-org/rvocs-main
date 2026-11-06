#!/usr/bin/env bash
# RVOCs unified entry point - one command to drive the sibling vendor repositories.
#
# Usage:
#   ./rvocs.sh [action] [--target TARGET] [--arch ARCH] [options] [-- passthrough args]
#
# Actions (mutually exclusive, pick one):
#   --version          print the rvocs-main version; with --target, print that
#                      target's version plus its upstream component pins
#   --list-releases    print published artifacts from RELEASES.list (global, or
#                      filtered by --target); newest first
#   --clone            clone the target vendor repository into the sibling dir
#                      (no target given: clone all of them)
#   --doctor           environment self-check: host conditions, known quirks and
#                      the commands to run next
#   --install          install host dependencies (tt-kmd / tt-smi / hugepages / udev)
#   --download [tag]   download the newest published artifact for the target from
#                      RELEASES.list; with an explicit tag, pull that image
#   --build            build from source (image or host bundle)
#   --deploy           start the inference container
#   --list-targets     print the target/action capability matrix
#
# Targets (--target; multiple separated by / or ,):
#   tt-host    host dependencies (tt-kmd / tt-smi / tt-flash / tt-topology / hugepages)
#   tt-stack   TT-Metal + vLLM inference image (aliases: tenstorrent, tt)
#   therock    ROCm/TheRock + vLLM inference image (aliases: amd, rocm)
#   rvocs      this repository itself (version / doctor only)
#   all        all of the above
#
# Options:
#   --target <t>                target(s); required for install/build/deploy
#   --arch x86|riscv|arm|host   target arch (default host; normalized to x86_64/riscv64/aarch64)
#   --engine vllm               inference engine (default vllm; llamacpp / sglang are
#                               planned and rejected until implemented)
#   --stage <stage>             forwarded to the sub-repo build (e.g. image / prep)
#   --proxy cn|direct|auto      network mode (default auto)
#   --workdir <dir>             work directory (default ./work)
#   -h, --help                  show this help
#   -- <args...>                pass through to the sub-repo script
#
# Examples:
#   ./rvocs.sh --version
#   ./rvocs.sh --list-releases
#   ./rvocs.sh --target amd --list-releases
#   ./rvocs.sh --target therock --clone
#   ./rvocs.sh --target tt-host --arch riscv --install
#   ./rvocs.sh --target tt-stack --arch riscv --download
#   ./rvocs.sh --target tt-stack --arch riscv --build
#   ./rvocs.sh --target tt-stack/therock --version
#
# Notes: sub-repos live as sibling directories (../rvocs-hcs-tenstorrent,
#        ../rvocs-hcs-amd). They are NOT fetched automatically: run
#        `./rvocs.sh --clone` (or --target <t> --clone) once, or point at an
#        existing copy with RVOCS_SIBLINGS_DIR / RVOCS_TT_HOST_DIR /
#        RVOCS_TT_STACK_DIR / RVOCS_THEROCK_DIR. This script only translates
#        arguments and chains stages; it never reimplements build logic.
#        See docs/CLI.md.
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
    --list-targets)  ACTION=list-targets; shift ;;
    --list-releases) ACTION=list-releases; shift ;;
    --clone)         ACTION=clone; shift ;;
    --download)
                     [ -n "$ACTION" ] && die "only one action allowed (already --$ACTION, got $1)"
                     ACTION=download; shift
                     # optional positional tag: --download rvocs-vllm-tt-amd64:v0.1.0
                     if [ $# -gt 0 ] && [ "${1#-}" = "$1" ]; then DOWNLOAD_REF="$1"; shift; fi ;;
    --version|--doctor|--install|--build|--deploy)
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
      for t in $(printf '%s' "$TARGETS_RAW" | tr '/,' '  '); do add_target "$t"; done ;;
  esac
fi

# read-only / orchestration actions work on all targets by default; actions with
# side effects must name a target explicitly.
case "$ACTION" in
  version)
    [ -n "$TARGETS" ] || TARGETS="rvocs" ;;
  doctor|list-targets|list-releases|clone)
    [ -n "$TARGETS" ] || TARGETS="$ALL_TARGETS" ;;
  download)
    # an explicit tag needs no target; otherwise require one
    if [ -n "${DOWNLOAD_REF:-}" ] && [ -z "$TARGETS" ]; then TARGETS="registry"; fi
    [ -n "$TARGETS" ] || die "download requires a tag or --target:
       ./rvocs.sh --download rvocs-vllm-tt-amd64:v0.1.0
       ./rvocs.sh --target tt-stack --arch riscv --download" ;;
  *)
    [ -n "$TARGETS" ] || die "$ACTION requires an explicit --target (choices: $REPO_IDS all)
       e.g. ./rvocs.sh --target tt-stack --arch riscv --$ACTION" ;;
esac

read -r -a TARGET_ARR <<< "$TARGETS"

case "$ACTION" in
  version|doctor|list-targets|list-releases|clone) AGGREGATE=1 ;;
  *)                                                AGGREGATE=0 ;;
esac

# only build actions need the sub-repo entry script in place
case "$ACTION" in
  build) NEEDS_ENTRY=1 ;;
  *)     NEEDS_ENTRY=0 ;;
esac

# ---------------------------------------------------------------- pre-flight checks
if [ "$AGGREGATE" = 0 ] && [ -z "${DOWNLOAD_REF:-}" ]; then
  for t in "${TARGET_ARR[@]}"; do
    assert_action_supported "$t" "$ACTION"
    [ "$t" = rvocs ] || assert_arch_supported "$t" "$ARCH"
  done
fi

mkdir -p "$WORK_DIR" "$LOG_DIR"
case "$ACTION" in
  # these actions never touch the network (except an explicit download, which
  # talks to the image registry / GitHub Releases, not github.com)
  list-targets|version|doctor|download|list-releases) : ;;
  *) resolve_proxy ;;
esac

# action scripts run as separate processes: export the facts they need
export ARCH PROXY_MODE PROXY STAGE WORK_DIR LOG_DIR SIBLINGS_DIR
export -n TARGETS 2>/dev/null || true
export RVOCS_SIBLINGS_DIR="$SIBLINGS_DIR"
export DOWNLOAD_REF="${DOWNLOAD_REF:-}"

if [ "$NEEDS_ENTRY" = 1 ] && [ -z "${DOWNLOAD_REF:-}" ]; then
  for t in "${TARGET_ARR[@]}"; do require_entry "$t" >/dev/null; done
  for t in "${TARGET_ARR[@]}"; do check_porting_branch "$t" "$ARCH"; done
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
  [ ${#EXTRA[@]} -gt 0 ] && printf '  %-12s: %s\n' "passthrough" "${EXTRA[*]}"
  for t in "${TARGET_ARR[@]}"; do
    if [ "$t" = rvocs ] || [ "$t" = registry ]; then continue; fi
    if d=$(repo_dir "$t" 2>/dev/null); then
      _br=$(repo_branch "$t"); _hd=$(repo_head "$t")
      printf '  %-13s: %s (%s @ %s)\n' "$t" "$d" "${_br:-not a git repo}" "${_hd:--}"
    else
      printf '  %-13s: \033[1;33mmissing\033[0m (clone with: ./rvocs.sh --target %s --clone)\n' "$t" "$t"
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

run_aggregate() { # one call with all targets
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
  version|doctor|list-releases|clone) run_aggregate ;;
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
