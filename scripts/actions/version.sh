#!/usr/bin/env bash
# action: version - what version is this, and which upstream is it built from
#
#   ./rvocs.sh --version                        # rvocs-main only
#   ./rvocs.sh --target tt-stack --version     # repo version + upstream components
#   ./rvocs.sh --target therock --version      # adds the AMD framework components
#   ./rvocs.sh --target all --version          # every target
#
# The repository version comes from <repo>/VERSION (single source of truth);
# component pins come from that repo's manifest.yaml; for therock the framework
# component pins come from its config/sources.sh and the version labels from
# framework_versions in that same manifest, so nothing is duplicated here.
#
# usage: bash scripts/actions/version.sh [target ...]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

TARGETS="${1:-${TARGETS:-rvocs}}"

row() { printf '  %-14s %s\n' "$1" "$2"; }

manifest_section() { if grep -q '^upstream:' "$1" 2>/dev/null; then echo upstream; else echo sources; fi; }

# component pins of one manifest section, one "name|ref|commit" per line
manifest_modules() { # manifest_modules <file> <section>
  awk -v sec="$2" '
    function flush() {
      if (name != "") printf "%s|%s|%s\n", name, ref, commit
      name=""; ref=""; commit=""
    }
    /^[A-Za-z_][A-Za-z0-9_.-]*:/ { flush(); insub = (index($0, sec":") == 1); next }
    insub && /^  [A-Za-z0-9_.-]+:[[:space:]]*$/ { flush(); name=$1; sub(":","",name); next }
    insub && name!="" && /^    ref:/    { r=$0; sub(/^[[:space:]]*ref:[[:space:]]*/,"",r);    sub(/[[:space:]]*#.*/,"",r); ref=r; next }
    insub && name!="" && /^    commit:/ { c=$0; sub(/^[[:space:]]*commit:[[:space:]]*/,"",c); sub(/[[:space:]]*#.*/,"",c); commit=c; next }
    END { flush() }
  ' "$1"
}

# scalar value inside a top-level block: yaml_block_value <file> <block> <key>
yaml_block_value() {
  awk -v b="$2" -v k="$3" '
    /^[A-Za-z_][A-Za-z0-9_]*:/ { inb = ($1 == b ":") ; next }
    inb && index($0, "  " k ":") == 1 { sub("^  " k ":[ \t]*", ""); sub(/[ \t]*#.*/, ""); print; exit }
  ' "$1"
}

print_modules() { # print_modules <manifest> <section>
  local mf="$1" sec="$2" n r c
  printf '  %s\n' "upstream components (manifest.yaml -> $sec):"
  printf '    %-26s %-24s %s\n' "COMPONENT" "REF" "COMMIT"
  while IFS='|' read -r n r c; do
    [ -n "$n" ] || continue
    printf '    %-26s %-24s %s\n' "$n" "${r:--}" "${c:0:12}"
  done < <(manifest_modules "$mf" "$sec")
}

# AMD framework components: pins come from rvocs-hcs-amd/config/sources.sh, the
# human-readable versions from framework_versions in that repo's manifest.yaml.
# Nothing is duplicated here, so the pin and the label cannot drift apart.
print_amd_components() { # <repo dir>
  local dir="$1" src mf name ref label rv
  src="$dir/config/sources.sh"
  mf="$dir/manifest.yaml"
  if [ ! -f "$src" ]; then
    row components "(missing: $src)"
    return 0
  fi
  printf '  %s\n' "framework components (pins: config/sources.sh, versions: manifest.yaml framework_versions):"
  printf '    %-16s %-16s %s\n' "COMPONENT" "VERSION" "PIN"
  while read -r name ref; do
    label="-"
    if [ -f "$mf" ]; then label=$(yaml_block_value "$mf" framework_versions "$name"); fi
    [ -n "$label" ] || label="-"
    printf '    %-16s %-16s %s\n' "$name" "$label" "$ref"
  done < <(awk '/^src_define /{printf "%s %s\n", $2, $4}' "$src")

  rv="-"
  if [ -f "$mf" ]; then rv=$(yaml_block_value "$mf" release rocm_version); fi
  printf '    %-16s %-16s %s\n' "rccl / nccl" "ROCm ${rv:--}" "TheRock 内置组件，未单独 pin"
}

printf '\n\033[1mRVOCs\033[0m\n'

for t in $TARGETS; do
  echo
  if [ "$t" = rvocs ]; then
    printf '\033[1;36mrvocs-main\033[0m  %s  %s\n' "$RVOCS_VERSION" "$(repo_label rvocs)"
    row version "$RVOCS_VERSION (VERSION)"
    row baseline "$RVOCS_BASELINE"
    row repository "$REPO_ROOT"
    row git "$(repo_branch rvocs) @ $(repo_head rvocs)  dirty=$(repo_dirty_count rvocs)"
    row describe "$(repo_describe rvocs)"
    row sub-repos "$SIBLINGS_DIR"
    echo "  hint: ./rvocs.sh --list-releases   # published artifacts (RELEASES.list)"
    continue
  fi

  if ! dir=$(repo_dir "$t" 2>/dev/null); then
    printf '\033[1;36m%s\033[0m  \033[1;33mnot found\033[0m\n' "$t"
    row candidates "$SIBLINGS_DIR/{$(repo_dirs_for "$t" | tr ' ' ',')}"
    row remote "$(repo_url "$t" 2>/dev/null || echo '(not configured)')"
    row hint "./rvocs.sh --target $t --clone"
    if [ "$t" = therock ]; then row components "(requires the repository: ./rvocs.sh --target therock --clone)"; fi
    continue
  fi

  ver=$(repo_version "$t" 2>/dev/null || echo unknown)
  printf '\033[1;36m%s\033[0m  %s  %s\n' "$t" "$ver" "$(repo_label "$t")"
  row version "$ver (VERSION)"
  row repository "$dir"
  row git "$(repo_branch "$t") @ $(repo_head "$t")  dirty=$(repo_dirty_count "$t")"
  row describe "$(repo_describe "$t")"

  mf="$dir/$(repo_manifest "$t")"
  if [ ! -f "$mf" ]; then
    row manifest "(missing: $mf)"
    if [ "$t" = therock ]; then print_amd_components "$dir"; fi
    continue
  fi

  case "$t" in
    tt-stack)
      print_modules "$mf" upstream
      ;;
    therock)
      rv=$(yaml_block_value "$mf" release rocm_version)
      ch=$(yaml_block_value "$mf" release channel)
      [ -n "$rv" ] && row release "ROCm $rv${ch:+ ($ch)}"
      print_modules "$mf" upstream
      print_amd_components "$dir"
      ;;
    tt-host)
      bv=$(yaml_block_value "$mf" bundle version)
      [ -n "$bv" ] && row bundle "$bv (manifest.yaml -> bundle.version)"
      row artifact "$(repo_part "$t")/dist/rvocs-tt-deps_${bv:-<ver>}_<debarch>.tar.zst, .deb"
      built=$(ls -1 "$dir/$(repo_part "$t")/dist"/rvocs-tt-deps_*.tar.zst 2>/dev/null | tail -n 1 || true)
      row "built" "${built:-(not built)}"
      print_modules "$mf" sources
      ;;
    *)
      print_modules "$mf" "$(manifest_section "$mf")"
      ;;
  esac
done

echo
