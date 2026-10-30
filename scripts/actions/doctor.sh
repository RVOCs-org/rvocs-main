#!/usr/bin/env bash
# action: doctor - environment self-check (the first step of Quickstart), known-quirk
#         detection, and the commands to run next
#
# Why check first: on RISC-V with heterogeneous accelerators, most failures are not in
# application code but in host semantics (glibc symbol versions, vendor rustc triples,
# hugepages, IOMMU, drivers). This script checks those preconditions once, reports them,
# and never modifies the system.
#
# usage: bash scripts/actions/doctor.sh [target ...]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

TARGETS="${1:-${TARGETS:-$ALL_TARGETS}}"
N_PASS=0; N_WARN=0; N_FAIL=0; N_FAIL_SOFT=0

pass() { N_PASS=$((N_PASS+1)); printf '  \033[1;32m[PASS]\033[0m %-26s %s\n' "$1" "$2"; }
note() { N_WARN=$((N_WARN+1)); printf '  \033[1;33m[WARN]\033[0m %-26s %s\n' "$1" "$2"; }
fail() { N_FAIL=$((N_FAIL+1)); printf '  \033[1;31m[FAIL]\033[0m %-26s %s\n' "$1" "$2"; }
# softfail: still reported as FAIL, but does not make doctor exit non-zero. Used
# when the problem blocks only one of the optional device stacks.
softfail() { N_FAIL_SOFT=$((N_FAIL_SOFT+1)); printf '  \033[1;31m[FAIL]\033[0m %-26s %s\n' "$1" "$2"; }
info() { printf '  \033[1;34m[INFO]\033[0m %-26s %s\n' "$1" "$2"; }

ver_ge() { # ver_ge <actual> <min>
  [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V 2>/dev/null | head -n1)" = "$2" ]
}

# kernel_ge <actual> <min>: dpkg version rules when available (7.0.0-38-generic
# vs 7.0.0-31-generic compares the revision numerically), sort -V otherwise
kernel_ge() {
  if have_cmd dpkg && dpkg --compare-versions "$1" ge "$2" 2>/dev/null; then
    return 0
  fi
  ver_ge "$1" "$2"
}

os_pretty_name() {
  ( . /etc/os-release 2>/dev/null && printf '%s' "${PRETTY_NAME:-unknown}" ) || uname -s
}

printf '\n\033[1mQuickstart environment check\033[0m  arch=%s  os=%s\n' "$ARCH" "$( (. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-unknown}") || uname -s)"

# ---------------------------------------------------------------- 1. platform
echo
echo "[1/6] Platform and OS"
host_arch=$(uname -m)
info "host arch" "$host_arch"

case "$host_arch" in
  riscv64|x86_64|aarch64) pass "arch supported" "$host_arch" ;;
  *) fail "arch supported" "untested arch $host_arch (verified: riscv64 / x86_64 / aarch64)" ;;
esac

if [ "$ARCH" != "$host_arch" ]; then
  note "cross build" "target is $ARCH but host is $host_arch: cross-arch builds are not supported (run on a matching host)"
else
  pass "target=host" "$ARCH"
fi

os_name=$(os_pretty_name)
kernel=$(uname -r)
info "os" "$os_name"
info "kernel" "$kernel"

# amdgpu on riscv64 is broken before 7.0.0-31-generic: too old a kernel makes the
# AMD stack unusable, so this is a blocking FAIL rather than a warning.
if [ "$ARCH" = riscv64 ]; then
  min_kernel="${RVOCS_MIN_KERNEL_RISCV64:-7.0.0-31-generic}"
  if kernel_ge "$kernel" "$min_kernel"; then
    pass "kernel (amdgpu)" "$kernel >= $min_kernel"
  else
    softfail "kernel (amdgpu)" "$kernel < $min_kernel: the amdgpu driver in older kernels is broken on riscv64 (affects --target therock only; does not block other targets)"
    cat <<EOF
       upgrade the kernel, then reboot:
         sudo apt-get update
         sudo apt-get install -y linux-generic linux-headers-generic
         sudo reboot
       after the reboot:
         uname -r && ./rvocs.sh --doctor
       (tt-kmd is rebuilt by DKMS on boot; if it is missing afterwards, re-run
        ./rvocs.sh --target tt-host --arch riscv --install --yes)
EOF
  fi
fi

glibc=$(ldd --version 2>/dev/null | head -n1 | grep -oE '[0-9]+\.[0-9]+' | head -n1 || true)
glibc=${glibc:-0.0}
if [ "$ARCH" = riscv64 ]; then
  if ver_ge "$glibc" "2.38"; then
    pass "glibc (SFPI prebuilt)" "$glibc >= 2.38"
  else
    fail "glibc (SFPI prebuilt)" "$glibc < 2.38: the bundled sfpi_7.78.0 package is unusable, falling back to an in-container source build (+90 min)"
  fi
  if ver_ge "$glibc" "2.41"; then
    pass "glibc (tt-deps abi3)" "$glibc >= 2.41"
  else
    note "glibc (tt-deps abi3)" "$glibc < 2.41: the pyluwen abi3 wheel may be unusable, tt-host will build from source"
  fi
else
  pass "glibc" "$glibc"
fi

# ---------------------------------------------------------------- 2. toolchain
echo
echo "[2/6] Base toolchain"
for c in git curl tar; do
  if have_cmd "$c"; then pass "$c" "$($c --version 2>/dev/null | head -n1)"; else fail "$c" "missing (apt-get install -y $c)"; fi
done

if have_cmd docker; then
  pass "docker CLI" "$(docker --version 2>/dev/null)"
  if docker info >/dev/null 2>&1; then pass "docker daemon" "reachable"; else note "docker daemon" "unreachable (add the user to the docker group, or check the rootless setup)"; fi
  if docker buildx version >/dev/null 2>&1; then pass "docker buildx" "$(docker buildx version 2>/dev/null | awk '{print $2}')"; else note "docker buildx" "missing: image builds need BuildKit/buildx"; fi
else
  note "docker" "not installed: both device-stack images need docker to build and deploy"
fi

have_cmd sudo && pass "sudo" "available" || note "sudo" "not installed: --install needs sudo"
have_cmd git-lfs && pass "git-lfs" "available" || note "git-lfs" "not installed: some TheRock components ship large files over LFS"

if [ "$ARCH" = riscv64 ]; then
  # quirk: a vendor-customized rustc host triple (e.g. riscv64a23-unknown-linux-gnu)
  # makes target-lexicon 0.12 fail, so pyluwen / maturin builds panic
  if have_cmd rustc; then
    rt=$(rustc -vV 2>/dev/null | awk '/^host:/{print $2}')
    case "$rt" in
      riscv64gc-unknown-linux-gnu|x86_64-unknown-linux-gnu|aarch64-unknown-linux-gnu) pass "rustc host" "$rt" ;;
      *) note "rustc host quirk" "vendor triple $rt: abi3 wheel builds panic (Invalid target name); put the rustup toolchain first in PATH" ;;
    esac
    have_cmd rustup && pass "rustup" "$(rustup --version 2>/dev/null | head -n1)" || note "rustup" "not installed: rustup is the easy way to get the official riscv64gc toolchain"
  else
    note "rustc" "not installed: only needed for tt-host's pyluwen/abi3 builds"
  fi
  have_cmd gfortran && pass "gfortran" "$(gfortran --version | head -n1)" || note "gfortran" "missing: needed for TheRock source builds (symlink gfortran-15 to /usr/local/bin/gfortran)"
  have_cmd patchelf && pass "patchelf" "$(patchelf --version 2>/dev/null)" || note "patchelf" "missing: TheRock kpack unpacking needs a patched patchelf (see docs/QUIRKS.md)"
else
  pass "gfortran/patchelf" "not needed outside riscv64"
fi

# ---------------------------------------------------------------- 3. disk
echo
echo "[3/6] Disk and memory"
case "$ARCH" in
  riscv64) need="$DISK_MIN_RISCV64" ;;
  aarch64) need="$DISK_MIN_AARCH64" ;;
  *)       need="$DISK_MIN_X86_64" ;;
esac
avail=$(df -Pk "$REPO_ROOT" 2>/dev/null | awk 'NR==2 {print int($4/1048576)}' || echo 0)
if [ "${avail:-0}" -ge "$need" ]; then
  pass "disk free" "${avail} GB >= watermark ${need} GB"
else
  note "disk free" "${avail} GB < watermark ${need} GB (TheRock sources+build ~200 GB; Tenstorrent-only is much smaller)"
fi
mem=$(awk '/^MemTotal:/{printf "%d", $2/1048576}' /proc/meminfo 2>/dev/null || echo 0)
if [ "${mem:-0}" -ge 32 ]; then pass "memory" "${mem} GB"; else note "memory" "${mem} GB: TheRock linking uses 4-8 GB per job, lower --jobs"; fi
# ---------------------------------------------------------------- 4. sub-repos
echo
echo "[4/6] Sub-repositories"
for t in $TARGETS; do
  [ "$t" = rvocs ] && continue
  if ! d=$(repo_dir "$t" 2>/dev/null); then
    note "$t" "not found (candidate dirs: $SIBLINGS_DIR/{$(repo_dirs_for "$t" | tr ' ' ',')}; or set $(repo_env_var "$t"))"
    continue
  fi
  if [ ! -f "$d/$(repo_entry "$t")" ]; then
    fail "$t" "missing entry point $(repo_entry "$t")"
    continue
  fi
  br=$(repo_branch "$t")
  want=$(repo_porting_branch "$t")
  if [ -z "$br" ]; then
    note "$t" "directory exists but is not a git repo (an extracted/copied snapshot?) - pins and branches cannot be tracked"
  elif [ -n "$want" ] && [ "$ARCH" = riscv64 ] && [ "$br" != "$want" ]; then
    note "$t branch" "on $br, riscv64 needs $want"
  else
    pass "$t" "$br @ $(repo_head "$t")"
  fi
  # outside a git repo (e.g. an extracted tt-host) the pipeline fails; fall back explicitly
  subs=$(git -C "$d" submodule status 2>/dev/null | wc -l | tr -d ' ') || subs=0
  miss=$(git -C "$d" submodule status 2>/dev/null | grep -c '^-') || miss=0
  if [ "${subs:-0}" -gt 0 ] && [ "${miss:-0}" -gt 0 ]; then
    note "$t submodules" "${miss}/${subs} uninitialized (git submodule update --init, or let build.sh's fetch stage do it)"
  fi
done

# ---------------------------------------------------------------- 5. devices
echo
echo "[5/6] Accelerators and device nodes"
tt_devs=$(ls -d /dev/tenstorrent* 2>/dev/null | tr '\n' ' ') || tt_devs=""
if [ -n "$tt_devs" ]; then
  pass "Tenstorrent devices" "$tt_devs"
  kmd=$(modinfo tenstorrent 2>/dev/null | awk '/^version:/{print $2}' || true)
  [ -n "$kmd" ] && pass "tt-kmd version" "$kmd" || note "tt-kmd version" "cannot read it (modinfo unavailable or the tenstorrent module is not loaded)"
else
  note "Tenstorrent devices" "no /dev/tenstorrent (normal on a card-less host; on a card host run --target tt-host --install first)"
fi

if [ -e /dev/kfd ] && ls /dev/dri/renderD* >/dev/null 2>&1; then
  pass "AMD devices" "/dev/kfd $(ls /dev/dri/renderD* 2>/dev/null | tr '\n' ' ')"
  grp_ok=0
  for g in render video; do id -nG 2>/dev/null | tr ' ' '\n' | grep -qx "$g" && grp_ok=$((grp_ok+1)); done
  if [ "$grp_ok" = 2 ]; then pass "user groups" "render + video"; else note "user groups" "render/video missing (deploy needs --group-add render --group-add video, or add the user to the groups)"; fi
else
  note "AMD devices" "no /dev/kfd or /dev/dri/renderD* (normal without a card or before the driver loads)"
fi

hp=$(awk '/^HugePages_Total/{print $2}' /proc/meminfo 2>/dev/null || echo 0)
if [ "${hp:-0}" -gt 0 ]; then pass "1G hugepages" "${hp} pages"; else note "1G hugepages" "0 pages (Tenstorrent containers need /dev/hugepages-1G; use tt-host's hugepages-setup)"; fi

# ---------------------------------------------------------------- 6. network
echo
echo "[6/6] Network and mirrors"
if curl -fsSI -m 8 https://github.com >/dev/null 2>&1; then
  pass "github.com" "direct access works (--proxy direct or auto will pick direct)"
else
  note "github.com" "direct access blocked -> use --proxy cn (gh-proxy + Tsinghua PyPI/Rust)"
fi

# ---------------------------------------------------------------- summary
echo
printf '============================================================\n'
printf ' PASS %d   WARN %d   FAIL %d (blocking)   FAIL %d (non-blocking)\n' \
  "$N_PASS" "$N_WARN" "$N_FAIL" "$N_FAIL_SOFT"
printf '============================================================\n'

if [ "$N_FAIL" -gt 0 ]; then
  echo "Blocking items above must be fixed first; WARN items depend on your scenario. See docs/QUIRKS.md."
  exit 1
fi

if [ "$N_FAIL_SOFT" -gt 0 ]; then
  echo "Non-blocking FAIL items above affect one device stack only (see the message); other targets stay usable."
fi

echo
a=$(arch_short "$ARCH")
echo "Next steps (pick what you need):"
echo "  1) host dependencies (driver/tools/hugepages):"
echo "       ./rvocs.sh --target tt-host --arch $a --install"
echo "  2) pull a ready-made image:"
echo "       ./rvocs.sh --target tt-stack --arch $a --download"
echo "       ./rvocs.sh --target therock      --arch $a --download"
echo "  3) build from source (long running; use nohup/tmux):"
echo "       ./rvocs.sh --target tt-stack --arch $a --build"
echo "       ./rvocs.sh --target therock      --arch $a --build"
echo "  4) verify and start the service:"
echo "       ./rvocs.sh --target tt-stack --arch $a --verify"
echo "       ./rvocs.sh --target tt-stack --arch $a --deploy --dry-run"
