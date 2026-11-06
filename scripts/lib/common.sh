#!/usr/bin/env bash
# ============================================================================
# RVOCs shared environment and helpers (sourced by rvocs.sh and scripts/actions/*.sh)
#
# Same conventions as the three sub-repos: path derivation, arch normalization,
# proxy mode, logging helpers. The only addition is cross-repo discovery
# (repo_dir / require_repo / target_supports).
# ============================================================================
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
# shellcheck source=../../config/defaults.sh
source "$REPO_ROOT/config/defaults.sh"
# shellcheck source=../../config/repos.sh
source "$REPO_ROOT/config/repos.sh"

WORK_DIR="${WORK_DIR:-$REPO_ROOT/work}"
LOG_DIR="${LOG_DIR:-$WORK_DIR/logs}"
RELEASES_FILE="${RELEASES_FILE:-$REPO_ROOT/RELEASES.list}"
# sibling root: the parent of rvocs-main by default (flat sibling layout)
SIBLINGS_DIR="${RVOCS_SIBLINGS_DIR:-$(cd "$REPO_ROOT/.." && pwd)}"

ARCH="${ARCH:-$(uname -m)}"
PROXY_MODE="${PROXY_MODE:-$DEFAULT_PROXY_MODE}"
PROXY="${PROXY:-}"          # 1|0, resolved by resolve_proxy
# --dry-run / --yes are gone from the CLI. Keep DRY_RUN fixed at 0 for
# the shared execution wrappers; actions with side effects always run.
DRY_RUN=0
STAGE="${STAGE:-}"
TARGETS="${TARGETS:-}"
TARGET="${TARGET:-}"

# ---------------------------------------------------------------- logging
log()  { printf '\033[1;32m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
step() { printf '\033[1;36m  ->\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }
ok()   { printf '\033[1;32m  [PASS]\033[0m %s\n' "$*"; }
bad()  { printf '\033[1;31m  [FAIL]\033[0m %s\n' "$*"; }
skip() { printf '\033[1;33m  [WARN]\033[0m %s\n' "$*"; }

require_cmd() { command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }
have_cmd()    { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------- architecture
# Accept short forms (x86 / riscv / arm) and emit the canonical names the
# sub-repos expect (x86_64 / riscv64 / aarch64).
normalize_arch() {
  case "${1:-}" in
    host|"")                      uname -m ;;
    x86|x86_64|amd64|x64)         echo x86_64 ;;
    riscv|riscv64|rv64|rv64gc)    echo riscv64 ;;
    arm|arm64|aarch64)            echo aarch64 ;;
    *)                            echo "$1" ;;
  esac
}

arch_ok() {
  case "$1" in x86_64|riscv64|aarch64) return 0 ;; *) return 1 ;; esac
}

# reverse direction: canonical name -> short form (for hint commands, matches --arch)
arch_short() {
  case "$1" in
    x86_64)  echo x86 ;;
    riscv64) echo riscv ;;
    aarch64) echo arm ;;
    *)       echo "$1" ;;
  esac
}

# ---------------------------------------------------------------- proxy
resolve_proxy() {
  [ -n "$PROXY" ] && return 0
  case "$PROXY_MODE" in
    cn)     PROXY=1 ;;
    direct) PROXY=0 ;;
    auto)
      if curl -fsSI -m 8 https://github.com >/dev/null 2>&1; then
        PROXY=0
      else
        PROXY=1
        warn "github.com is unreachable, enabling mirror mode (gh-proxy + Tsinghua PyPI/Rust)"
      fi ;;
    *) die "unknown --proxy mode: $PROXY_MODE (expected cn|direct|auto)" ;;
  esac
  export PROXY
  if [ "$PROXY" = 1 ]; then
    export PIP_INDEX_URL=https://pypi.tuna.tsinghua.edu.cn/simple
    export PIP_EXTRA_INDEX_URL=https://pypi.tuna.tsinghua.edu.cn/simple
    export UV_INDEX_URL=https://pypi.tuna.tsinghua.edu.cn/simple
    export UV_DEFAULT_INDEX=https://pypi.tuna.tsinghua.edu.cn/simple
    export RUSTUP_DIST_SERVER=https://mirrors.tuna.tsinghua.edu.cn/rustup
    export RUSTUP_UPDATE_ROOT=https://mirrors.tuna.tsinghua.edu.cn/rustup/rustup
  fi
}

gh_url() { # gh_url <https://github.com/...>
  if [ "${PROXY:-0}" = 1 ]; then echo "https://gh-proxy.com/$1"; else echo "$1"; fi
}

# ---------------------------------------------------------------- execution wrappers
run() {
  if [ "$DRY_RUN" = 1 ]; then
    printf '  [dry-run] %s\n' "$*"
    return 0
  fi
  "$@"
}

# run a command inside a sub-repo: run_in <dir> <cmd...>
run_in() {
  local dir="$1"; shift
  if [ "$DRY_RUN" = 1 ]; then
    printf '  [dry-run] (cd %s && %s)\n' "$dir" "$*"
    return 0
  fi
  ( cd "$dir" && "$@" )
}

# Table rendering: tab-separated columns aligned by column(1); without column
# (e.g. Git Bash) the raw TSV is printed rather than pretending to align.
render_tsv() { if have_cmd column; then column -t -s "$(printf '\t')"; else cat; fi; }

quote_cmd() { # join an argument vector into a copy-pasteable command line
  local a out=""
  for a in "$@"; do
    case "$a" in
      *[[:space:]]*|*\"*|*\'*) out="$out $(printf '%q' "$a")" ;;
      *)                       out="$out $a" ;;
    esac
  done
  printf '%s' "${out# }"
}

# ---------------------------------------------------------------- sub-repo discovery
repo_env_var() { printf 'RVOCS_%s_DIR' "$(printf '%s' "$1" | tr '[:lower:]-' '[:upper:]_')"; }

# repo_dir <id> -> absolute path; returns 1 when absent
repo_dir() {
  local id="$1" var dir cand
  var=$(repo_env_var "$id")
  dir="${!var:-}"
  if [ -n "$dir" ]; then
    [ -d "$dir" ] || die "$var points to a missing directory: $dir"
    ( cd "$dir" && pwd )
    return 0
  fi
  if [ "$id" = rvocs ]; then printf '%s' "$REPO_ROOT"; return 0; fi
  for cand in $(repo_dirs_for "$id"); do
    if [ -d "$SIBLINGS_DIR/$cand" ]; then
      ( cd "$SIBLINGS_DIR/$cand" && pwd )
      return 0
    fi
  done
  return 1
}
# In cn mode, let git subprocesses go through gh-proxy without touching the
# user's global gitconfig.
run_git() {
  if [ "${PROXY:-0}" = 1 ]; then
    git -c "url.https://gh-proxy.com/https://github.com/.insteadOf=https://github.com/" "$@"
  else
    git "$@"
  fi
}

# Clone a vendor repository explicitly (`--clone`). Nothing clones implicitly,
# so a missing repository produces a clear, actionable error instead of silently
# reaching the network. The clone is built in a temporary directory: an existing
# checkout is never removed, even when the clone fails.
clone_repo() { # clone_repo <id> -> prints the path
  local id="$1" url branch dest
  if dest=$(repo_dir "$id" 2>/dev/null); then
    log "already present: $dest" >&2
    printf '%s' "$dest"
    return 0
  fi
  url=$(repo_url "$id" 2>/dev/null) || return 1
  [ -n "$url" ] || return 1
  branch=$(repo_branch_for "$id" "$ARCH")
  dest="$SIBLINGS_DIR/$(repo_dirs_for "$id" | awk '{print $1}')"

  require_cmd git
  log "cloning $url (branch $branch)" >&2
  mkdir -p "$SIBLINGS_DIR"

  # Sub-repos are single-branch on main; a mirror that still uses master is
  # accepted too: try the configured branch, then the other common name, then let
  # git pick the remote default.
  local try_branches="$branch" b cloned=0 tmp
  for b in main master; do
    case " $try_branches " in
      *" $b "*) ;;
      *) try_branches="$try_branches $b" ;;
    esac
  done
  tmp="$dest.partial.$$"
  for b in $try_branches; do
    rm -rf "$tmp"
    if run_git clone --branch "$b" "$url" "$tmp"; then
      cloned=1
      [ "$b" = "$branch" ] || log "cloned branch $b of $url (configured: $branch)" >&2
      break
    fi
    warn "branch $b not found on $url"
  done
  if [ "$cloned" = 0 ]; then
    rm -rf "$tmp"
    if run_git clone "$url" "$tmp"; then
      cloned=1
      log "cloned the remote default branch of $url" >&2
    fi
  fi
  if [ "$cloned" = 0 ]; then
    warn "clone failed: $url"
    rm -rf "$tmp"
    return 1
  fi
  if [ -e "$dest" ]; then
    rm -rf "$tmp"
    warn "refusing to overwrite an existing directory: $dest"
    return 1
  fi
  if ! mv "$tmp" "$dest"; then
    warn "could not move the clone into place: $dest"
    rm -rf "$tmp"
    return 1
  fi
  printf '%s' "$dest"
}

# require_repo <id> -> directory; never fetches anything
require_repo() {
  local id="$1" dir var
  if dir=$(repo_dir "$id" 2>/dev/null); then printf '%s' "$dir"; return 0; fi
  var=$(repo_env_var "$id")
  die "sub-repo $id not found.
       expected: $SIBLINGS_DIR/$(repo_dirs_for "$id" | awk '{print $1}')
       fetch it: ./rvocs.sh --target $id --clone
       or point at an existing copy: $var=/path/to/repo
       remote:   $(repo_url "$id" 2>/dev/null || echo '(not configured)')"
}

# require_entry <id> -> directory that also contains the build entry point
require_entry() {
  local id="$1" dir entry
  dir=$(require_repo "$id")
  entry=$(repo_entry "$id")
  if [ ! -f "$dir/$entry" ]; then
    die "$id is missing the entry script: $dir/$entry"
  fi
  printf '%s' "$dir"
}

# entry script path of a target (used when invoking the sub-repo build)
entry_for() { # entry_for <id>
  repo_entry "$1"
}

# repo_git <id> <git args...> (empty output when the directory is not a git repo)
repo_git() {
  local id="$1"; shift
  local dir
  dir=$(repo_dir "$id" 2>/dev/null) || return 1
  git -C "$dir" "$@" 2>/dev/null || true
}

repo_branch() { repo_git "$1" rev-parse --abbrev-ref HEAD; }
repo_head()   { repo_git "$1" rev-parse --short HEAD; }
repo_describe() {
  local dir d
  dir=$(repo_dir "$1" 2>/dev/null) || { printf '(repo missing)'; return 0; }
  if ! git -C "$dir" rev-parse HEAD >/dev/null 2>&1; then printf '(no commits)'; return 0; fi
  d=$(git -C "$dir" describe --tags --always 2>/dev/null || true)
  printf '%s' "${d:-(no commits)}"
}
repo_dirty_count() {
  local out
  out=$(repo_git "$1" status --porcelain)
  [ -n "$out" ] && printf '%s' "$out" | wc -l | tr -d ' ' || printf '0'
}

# ---------------------------------------------------------------- validation
assert_arch_supported() { # assert_arch_supported <id> <arch>
  local id="$1" arch="$2" a
  for a in $(target_archs "$id"); do
    [ "$a" = "$arch" ] && return 0
  done
  die "$id does not support arch $arch (supported: $(target_archs "$id"))"
}

assert_action_supported() { # assert_action_supported <id> <action>
  local id="$1" action="$2"
  if target_supports "$id" "$action"; then return 0; fi
  die "$id does not support --$action. $(target_hint "$id" "$action")"
}

# riscv64 source builds need the porting branch; fail early with a fix command
# instead of letting the sub-repo blow up deep inside the build.
check_porting_branch() { # check_porting_branch <id> <arch>
  local id="$1" arch="$2" want branch
  [ "$arch" = riscv64 ] || return 0
  want=$(repo_porting_branch "$id")
  [ -n "$want" ] || return 0
  branch=$(repo_branch "$id")
  [ -n "$branch" ] || return 0
  if [ "$branch" != "$want" ]; then
    die "$id must use branch $want on riscv64 (current: ${branch:-unknown}).
       fix: git -C $(repo_dir "$id") checkout $want && git -C $(repo_dir "$id") submodule update --init"
  fi
}

# ---------------------------------------------------------------- images
image_tag_for() { # image_tag_for <id> [arch]
  local id="$1" arch="${2:-$ARCH}"
  case "$id" in
    tt-stack) tt_image_tag "$arch" ;;
    therock)     amdg_image_tag "$arch" ;;
    *)           return 1 ;;
  esac
}

image_exists() { # image_exists <tag>
  have_cmd docker || return 1
  docker image inspect "$1" >/dev/null 2>&1
}

# ---------------------------------------------------------------- published artifacts
# Pull a published image and keep the short name, so --deploy (which uses
# the local name) does not need to know where it came from.
registry_ref() { # registry_ref <name:tag> -> <registry>/<name:tag>
  printf '%s/%s' "${RVOCS_REGISTRY%/}" "$1"
}

# OCI name of this host (amd64 / arm64 / riscv64)
host_image_arch() {
  case "$(uname -m)" in
    x86_64)        echo amd64 ;;
    aarch64|arm64) echo arm64 ;;
    riscv64)       echo riscv64 ;;
    *)             uname -m ;;
  esac
}

# architecture encoded in the image name (rvocs-vllm-tt-amd64, ...-r9700-riscv64)
ref_image_arch() { # ref_image_arch <name:tag> -> amd64|arm64|riscv64 or empty
  local name="${1%%:*}"
  case "$name" in
    *-amd64)   printf 'amd64' ;;
    *-arm64)   printf 'arm64' ;;
    *-riscv64) printf 'riscv64' ;;
  esac
}

pull_published() { # pull_published <name:tag>
  local ref="$1" full img_arch host_arch
  full=$(registry_ref "$ref")
  img_arch=$(ref_image_arch "$ref")
  host_arch=$(host_image_arch)

  # a tag for another architecture must be pulled with an explicit platform,
  # otherwise docker refuses with "no matching manifest for linux/<host>"
  local plat=""
  if [ -n "$img_arch" ] && [ "$img_arch" != "$host_arch" ]; then
    plat="linux/$img_arch"
    warn "image is $plat but this host is linux/$host_arch: pulling with --platform (it will not run here)"
  fi

  if [ "$DRY_RUN" = 1 ]; then
    if [ -n "$plat" ]; then
      printf '  [dry-run] docker pull --platform %s %s\n' "$plat" "$full"
    else
      printf '  [dry-run] docker pull %s\n' "$full"
    fi
    if [ "$full" != "$ref" ]; then
      printf '  [dry-run] docker tag %s %s\n' "$full" "$ref"
      printf '  [dry-run] docker rmi %s\n' "$full"
    fi
    return 0
  fi

  require_cmd docker
  log "pulling: $full${plat:+ (--platform $plat)}"
  if [ -n "$plat" ]; then
    run docker pull --platform "$plat" "$full" \
      || die "docker pull failed.
       tag architecture: ${img_arch:-unknown}, host: $host_arch
       use the tag matching this host: rvocs-<stack>-...-${host_arch}:<version>"
  else
    run docker pull "$full"
  fi
  if [ "$full" != "$ref" ]; then
    run docker tag "$full" "$ref"
    # keep a single reference: drop the registry-prefixed tag so `docker images`
    # does not list the same image twice (the image stays reachable as $ref)
    if run docker rmi "$full" >/dev/null 2>&1; then
      log "tagged locally as: $ref (registry reference removed)"
    else
      warn "could not drop the registry reference $full (harmless; the image is tagged as $ref)"
    fi
  fi
}

# ---------------------------------------------------------------- published releases
# RELEASES.list is the single source of truth for published artifacts. One line
# per artifact, newest first:  <target> <version> <artifact>
release_rows() { # -> target<TAB>version<TAB>artifact
  [ -f "$RELEASES_FILE" ] || return 1
  awk 'BEGIN { FS="[[:space:]]+" }
       /^[[:space:]]*#/ || NF == 0 { next }
       NF >= 3 { print $1 "\t" $2 "\t" $3 }' "$RELEASES_FILE"
}

release_latest_version() { # <target> -> newest version listed for the target
  local t="$1"
  { release_rows || true; } | awk -v t="$t" '$1 == t { print $2; exit }'
}

release_latest_artifacts() { # <target> -> artifacts of the newest version
  local t="$1" v
  v=$(release_latest_version "$t")
  [ -n "$v" ] || return 1
  { release_rows || true; } | awk -v t="$t" -v v="$v" '$1 == t && $2 == v { print $3 }'
}

release_artifact_for_arch() { # <target> <arch> -> artifact matching that arch
  local t="$1" arch="$2" a img deb
  img=$(image_arch "$arch")
  deb=$(arch_deb "$arch")
  while IFS= read -r a; do
    case "$a" in
      *_"$deb".deb|*-"$img":*) printf '%s' "$a"; return 0 ;;
    esac
  done < <(release_latest_artifacts "$t" || true)
  return 1
}

release_download_url() { # <version> <artifact> -> tt-host .deb download URL
  printf '%s/download/%s/%s' "${RVOCS_TT_HOST_RELEASES_PAGE%/}" "$1" "$2"
}

published_image_for() { # <target> <arch> -> published tag, else the local build name
  local t="$1" arch="$2" ref
  if ref=$(release_artifact_for_arch "$t" "$arch"); then
    printf '%s' "$ref"
  else
    image_tag_for "$t" "$arch"
  fi
}

# newest previously downloaded .deb in the work dir
tt_host_deb_local() { # <debarch>
  ls -1t "$WORK_DIR"/packages/*_"$1".deb 2>/dev/null | head -1 || true
}
