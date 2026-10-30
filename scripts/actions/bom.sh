#!/usr/bin/env bash
# action: bom - print the full-stack version matrix (BOM)
# sources: the bom section of manifest.yaml (human-readable) plus the live git
#          state of each sub-repo (machine facts)
#
#   --bom              print the matrix
#   --bom --sync       rewrite the bom versions from each sub-repo's manifest
#                      (ref + commit); --dry-run shows the changes without writing
#
# usage: bash scripts/actions/bom.sh [target ...]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

MANIFEST="$REPO_ROOT/manifest.yaml"

# bom entries as TSV: component / version / target / source
bom_entries() {
  awk '
    function flush() {
      if (comp != "") printf "%s\t%s\t%s\t%s\n", comp, ver, tgt, src
      comp=""; ver=""; tgt=""; src=""
    }
    /^[[:space:]]*-[[:space:]]*component:/ { flush(); comp=$0; sub(/^[[:space:]]*-[[:space:]]*component:[[:space:]]*/, "", comp); gsub(/"/, "", comp); next }
    /^[[:space:]]+version:/ { ver=$0; sub(/^[[:space:]]*version:[[:space:]]*/, "", ver); gsub(/"/, "", ver); next }
    /^[[:space:]]+target:/  { tgt=$0; sub(/^[[:space:]]*target:[[:space:]]*/, "", tgt); gsub(/"/, "", tgt); next }
    /^[[:space:]]+source:/  { src=$0; sub(/^[[:space:]]*source:[[:space:]]*/, "", src); gsub(/"/, "", src); next }
    END { flush() }
  ' "$MANIFEST"
}

# module pins of one manifest section as TSV: normalized-name / version-string
# version-string = "<ref> (<short sha>)" so the table stays readable
module_pins() { # module_pins <target-id> <section>
  local t="$1" sec="$2" dir f
  dir=$(repo_dir "$t" 2>/dev/null) || return 0
  f="$dir/$(repo_manifest "$t")"
  [ -f "$f" ] || return 0
  awk -v sec="$sec" '
    function norm(s) { s=tolower(s); gsub(/\([^)]*\)/, "", s); gsub(/[^a-z0-9]/, "", s); return s }
    function flush() {
      if (name != "") printf "%s\t%s\t%s\n", norm(name), ref, commit
      name=""; ref=""; commit=""
    }
    /^[A-Za-z_][A-Za-z0-9_]*:/ { insub = (index($0, sec":") == 1); flush(); next }
    insub && /^  [A-Za-z0-9_.-]+:[[:space:]]*$/ { flush(); name=$1; sub(":","",name); next }
    insub && name!="" && /^    ref:/    { r=$0; sub(/^[[:space:]]*ref:[[:space:]]*/,"",r);    sub(/[[:space:]]*#.*/,"",r); ref=r; next }
    insub && name!="" && /^    commit:/ { c=$0; sub(/^[[:space:]]*commit:[[:space:]]*/,"",c); sub(/[[:space:]]*#.*/,"",c); commit=c; next }
    END { flush() }
  ' "$f"
}

printf '\n\033[1mRVOCs full-stack BOM\033[0m  baseline=%s  manifest=%s\n\n' "$RVOCS_BASELINE" "${MANIFEST#"$REPO_ROOT"/}"
[ -f "$MANIFEST" ] || die "manifest.yaml is missing"

# ASCII header: column(1) miscounts double-width characters, so non-ASCII text
# only appears in the explanatory line above the table.
printf 'component / version (pin) / target / source\n\n'
{
  printf '%s\t%s\t%s\t%s\n' "COMPONENT" "VERSION" "TARGET" "SOURCE"
  bom_entries
} | render_tsv

echo
printf '\033[1mLive sub-repo state\033[0m (authoritative pins are the gitlinks in each repo, not this table)\n'
for t in $(printf '%s' "$ALL_TARGETS" | tr ' ' '\n' | grep -v '^rvocs$'); do
  if d=$(repo_dir "$t" 2>/dev/null); then
    printf '  %-14s %-18s %-10s %s\n' "$t" "$(repo_branch "$t")" "$(repo_head "$t")" "$(repo_describe "$t")"
  else
    printf '  %-14s \033[1;33mnot found\033[0m\n' "$t"
  fi
done

# ---------------------------------------------------------------- --sync
if [ "${BOM_SYNC:-0}" = 1 ]; then
  echo
  printf '\033[1mSync bom versions from sub-repo manifests\033[0m\n'

  pins=$(mktemp); updates=$(mktemp); skipped=$(mktemp)
  trap 'rm -f "$pins" "$updates" "$skipped"' EXIT

  # repo-qualified lookup: <repo> <TAB> <normalized module> <TAB> <version>
  for pair in "tt-host:sources" "tt-stack:upstream" "therock:upstream"; do
    t="${pair%%:*}"; sec="${pair##*:}"
    while IFS=$'\t' read -r n r c; do
      [ -n "$n" ] && printf '%s\t%s\t%s\t%s\n' "$t" "$n" "$r" "$c" >> "$pins"
    done < <(module_pins "$t" "$sec")
  done

  norm_name() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed 's/([^)]*)//g; s/[^a-z0-9]//g'; }

  while IFS=$'\t' read -r comp ver tgt src; do
    [ -n "$comp" ] || continue
    case "$src" in
      *tt-host*) repo=tt-host ;;
      *tt-stack*)  repo=tt-stack ;;
      *amd-the-rock*|*therock*) repo=therock ;;
      *) repo="" ;;
    esac
    [ -n "$repo" ] || { printf '%s\n' "$comp" >> "$skipped"; continue; }

    key=$(norm_name "$comp")
    mref=""; msha=""
    # ROCm comes from release.rocm_version, not from an upstream module
    if [ "$repo" = therock ] && [ "$key" = rocm ]; then
      d=$(repo_dir therock 2>/dev/null || true)
      if [ -n "$d" ] && [ -f "$d/manifest.yaml" ]; then
        mref=$(sed -n 's/^  rocm_version: *\([^ #]*\).*/\1/p' "$d/manifest.yaml" | head -1)
      fi
    fi
    if [ -z "$mref" ]; then
      mref=$(awk -F'\t' -v r="$repo" -v k="$key" '$1==r && $2==k {print $3; exit}' "$pins")
      msha=$(awk -F'\t' -v r="$repo" -v k="$key" '$1==r && $2==k {print $4; exit}' "$pins")
    fi
    if [ -z "$mref" ] && [ -z "$msha" ]; then
      printf '%s\n' "$comp" >> "$skipped"
      continue
    fi

    # keep a curated note in parentheses; a hex note is replaced by the pinned sha
    note=$(printf '%s' "$ver" | sed -n 's/^[^(]*(\([^)]*\)).*/\1/p')
    if printf '%s' "$note" | grep -Eq '^[0-9a-fA-F]{7,40}$'; then note=""; fi
    if [ -n "$msha" ]; then
      sha8=$(printf '%s' "$msha" | cut -c1-8)
      note="${note:-$sha8}"
    fi
    hit="$mref"; [ -n "$note" ] && hit="$mref ($note)"

    if [ "$hit" != "$ver" ]; then
      printf '%s\t%s\t%s\n' "$comp" "$ver" "$hit" >> "$updates"
    fi
  done < <(bom_entries)

  n_upd=$(wc -l < "$updates" | tr -d ' ')
  n_skip=$(wc -l < "$skipped" | tr -d ' ')

  if [ "$n_upd" -eq 0 ]; then
    echo "  already in sync ($n_skip component(s) without an upstream module, left as-is)"
  else
    while IFS=$'\t' read -r comp old new; do
      printf '  %-26s %s -> %s\n' "$comp" "$old" "$new"
    done < "$updates"

    if [ "${DRY_RUN:-0}" = 1 ]; then
      echo "  [dry-run] manifest.yaml not written ($n_upd change(s))"
    else
      tmp=$(mktemp)
      awk -v mapf="$updates" '
        BEGIN { FS="\t"; while ((getline line < mapf) > 0) { n=split(line, a, FS); m[a[1]]=a[3] } }
        /^bom:/ { inbom=1; print; next }
        inbom && /^[A-Za-z_]/ { inbom=0 }
        inbom && /^[[:space:]]*-[[:space:]]*component:/ {
          c=$0; sub(/^[[:space:]]*-[[:space:]]*component:[[:space:]]*/,"",c); gsub(/"/,"",c); comp=c; print; next
        }
        inbom && comp!="" && /^[[:space:]]+version:/ && (comp in m) {
          printf "    version: \"%s\"\n", m[comp]; next
        }
        { print }
      ' "$MANIFEST" > "$tmp"
      mv "$tmp" "$MANIFEST"
      echo "  manifest.yaml updated: $n_upd component version(s)"
    fi
  fi
  if [ "$n_skip" -gt 0 ]; then
    echo "  kept manual: $(tr '\n' ' ' < "$skipped")"
  fi
fi

echo
echo "Note: to bump the baseline, commit the new gitlink in the sub-repo first, then run --bom --sync."
echo "      The BOM is display-only; build behaviour is driven by each sub-repo's own manifest/gitlink."
