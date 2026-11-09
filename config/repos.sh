#!/usr/bin/env bash
# ============================================================================
# Target registry - the single source of truth for "which sub-repos exist and
# what they can do" in this repository.
#
# Design choice: sub-repos are reused as sibling directories; sources are never
# copied and submodules are not used.
#   - each repo evolves and versions independently (no duplicated sources);
#   - rvocs-main only does discovery, argument translation and stage chaining,
#     and never reimplements build logic.
#
# Target ids name a *part* of a vendor repository, not the old repository names:
#   tt-host   host/  of rvocs-hcs-tenstorrent  (drivers, tools, hugepages, udev)
#   tt-stack  stack/ of rvocs-hcs-tenstorrent  (TT-Metal + vLLM image)
#   therock   whole rvocs-hcs-amd              (ROCm/TheRock + vLLM image)
#
# To add a target:
#   1) add branches below for normalize_target / repo_dirs_for / repo_url /
#      repo_label / repo_role / target_actions (generic actions are reused);
#   2) add an entry to manifest.yaml;
#   3) add a section to docs/REPOS.md.
# ============================================================================

# Targets included in read-only aggregation (rvocs itself included)
ALL_TARGETS="rvocs tt-host tt-stack therock"

# directory alias -> canonical id
normalize_target() {
  case "$1" in
    rvocs|rvocs-main|main|self)                      echo rvocs ;;
    tt-host|host|boot)                               echo tt-host ;;
    tt-stack|stack|tenstorrent|tt|tt-metal|ttnn)     echo tt-stack ;;
    therock|amd|amd-the-rock|amd-hcs|rocm)           echo therock ;;
    *) return 1 ;;
  esac
}

# canonical id -> accepted directory names (probed in order under $RVOCS_SIBLINGS_DIR)
# Vendor repositories follow the rvocs-hcs-{vendor} naming; tt-host and tt-stack
# are two parts of the same vendor repository.
repo_dirs_for() {
  case "$1" in
    tt-host|tt-stack) echo "rvocs-hcs-tenstorrent" ;;
    therock)          echo "rvocs-hcs-amd" ;;
    rvocs)            echo "." ;;
    *)                return 1 ;;
  esac
}

# canonical id -> default remote (cloned on first use; override with RVOCS_<ID>_URL)
repo_url() {
  case "$1" in
    rvocs)             echo "${RVOCS_URL:-https://github.com/RVOCs-org/rvocs-main.git}" ;;
    tt-host|tt-stack)  echo "${RVOCS_TENSTORRENT_URL:-https://github.com/RVOCs-org/rvocs-hcs-tenstorrent.git}" ;;
    therock)           echo "${RVOCS_THEROCK_URL:-https://github.com/RVOCs-org/rvocs-hcs-amd.git}" ;;
    *)                 return 1 ;;
  esac
}

# branch to clone: every repository is single-branch on `main`. ensure_repo()
# falls back to the remote default when the configured name is missing (an old
# checkout that still uses `master` is accepted), so RVOCS_BRANCH only has to be
# set for a fork that uses another name. Architecture differences live in the
# repos' own patches/<arch>/ layers, not in branches.
repo_branch_for() { # repo_branch_for <id> <arch>
  printf '%s' "${RVOCS_BRANCH:-main}"
}

repo_label() {
  case "$1" in
    rvocs)    echo "rvocs-main (orchestration layer)" ;;
    tt-host)  echo "rvocs-hcs-tenstorrent/host (drivers and tools)" ;;
    tt-stack) echo "rvocs-hcs-tenstorrent/stack (TT-Metal + vLLM image)" ;;
    therock)  echo "rvocs-hcs-amd (ROCm/TheRock + vLLM image)" ;;
    *)        return 1 ;;
  esac
}

repo_role() {
  case "$1" in
    rvocs)    echo "unified CLI / full-stack BOM / cross-repo acceptance" ;;
    tt-host)  echo "tt-kmd driver, tt-smi/tt-flash/tt-topology, 1G hugepages, udev" ;;
    tt-stack) echo "tt-metal + vLLM + vllm-tt-plugin built into an inference image" ;;
    therock)  echo "TheRock (ROCm) super-project + torch/triton/vLLM built into an image" ;;
    *)        return 1 ;;
  esac
}

# expected porting branch: none - every repository is single-branch now, the
# riscv64 porting layers live in each repo's patches/riscv64/
repo_porting_branch() {
  return 0
}

# sub-repo build entry point (relative to the repository root). tt-host and
# tt-stack resolve to the same vendor repository but different parts.
repo_entry() { # repo_entry <id>
  case "$1" in
    tt-host)  echo "host/scripts/build.sh" ;;
    tt-stack) echo "stack/scripts/build.sh" ;;
    *)        echo "scripts/build.sh" ;;
  esac
}
REPO_ENTRY="scripts/build.sh"   # default, kept for compatibility

# manifest holding this target's pins (relative to the repository root)
repo_manifest() { # repo_manifest <id>
  case "$1" in
    tt-host)  echo "host/manifest.yaml" ;;
    tt-stack) echo "stack/manifest.yaml" ;;
    *)        echo "manifest.yaml" ;;
  esac
}

# part directory of a target inside its repository (where dist/ and work/ live)
repo_part() { # repo_part <id>
  case "$1" in
    tt-host)  echo "host" ;;
    tt-stack) echo "stack" ;;
    *)        echo "." ;;
  esac
}

# actions supported by each target (capability matrix)
target_actions() {
  case "$1" in
    rvocs)    echo "version doctor list-targets list-releases" ;;
    tt-host)  echo "install build download version doctor list-targets list-releases clone" ;;
    tt-stack) echo "build download version doctor list-targets list-releases clone" ;;
    therock)  echo "build download version doctor list-targets list-releases clone" ;;
    *)        return 1 ;;
  esac
}

target_supports() { # target_supports <id> <action>
  case " $(target_actions "$1" 2>/dev/null || true) " in
    *" $2 "*) return 0 ;;
    *)        return 1 ;;
  esac
}

# alternative suggestion when an action is unsupported (more useful than a bare error)
target_hint() { # target_hint <id> <action>
  local id="$1" action="$2"
  case "$id:$action" in
    tt-stack:install|therock:install)
      echo "host dependencies (driver/tools/hugepages) are handled by: ./rvocs.sh --target tt-host --arch <arch> --install" ;;
    rvocs:*)
      echo "rvocs is the orchestration layer itself; available actions: $(target_actions rvocs)" ;;
    *)
      echo "$id supports: $(target_actions "$id")" ;;
  esac
}

# architectures supported by each target (doctor and validation)
target_archs() {
  case "$1" in
    tt-host)  echo "riscv64 x86_64" ;;
    tt-stack) echo "riscv64 x86_64" ;;
    therock)  echo "riscv64 x86_64" ;;
    *)        echo "riscv64 x86_64" ;;
  esac
}

# Version of a target repository. <repo>/VERSION is the single source of truth
# (plain text, one line, no shell/YAML parsing), so build scripts and this CLI
# read the same value; rvocs-main keeps its own in config/defaults.sh.
repo_version() { # repo_version <id> -> version string, "unknown" when absent
  local id="$1" dir f
  if [ "$id" = rvocs ]; then printf '%s' "$RVOCS_VERSION"; return 0; fi
  dir=$(repo_dir "$id" 2>/dev/null) || return 1
  f="$dir/VERSION"
  if [ -f "$f" ]; then tr -d '[:space:]' < "$f"; else printf 'unknown'; fi
}
