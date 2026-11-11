#!/usr/bin/env bash
# tool: digest - print the sha256 that RELEASES.list expects for an artifact
#
#   ./scripts/tools/digest.sh <artifact>...
#   ./scripts/tools/digest.sh --row <target> <version> <artifact>
#
#   <artifact>  a .deb path on disk, or an image reference (name:tag)
#
# .deb  : sha256sum of the file, printed as sha256:<hex>
# image : the registry manifest digest docker records in RepoDigests (the tag's
#         Docker-Content-Digest). Images that are not present locally are looked
#         up in the registry (SWR anonymous pull token), so a maintainer does not
#         have to pull 15 GB just to fill in the digest column.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

ACCEPT="application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.docker.distribution.manifest.v2+json,application/vnd.oci.image.manifest.v1+json"

usage() {
  cat <<'EOF'
usage: scripts/tools/digest.sh <artifact>...
       scripts/tools/digest.sh --row <target> <version> <artifact>

  <artifact>  .deb file path, or a docker image reference (name:tag)

  default  prints  <artifact>  sha256:...
  --row    prints a ready-to-paste RELEASES.list line instead

examples:
  scripts/tools/digest.sh dist/rvocs-tt-deps_v0.1.0_amd64.deb
  scripts/tools/digest.sh rvocs-vllm-tt-amd64:v0.1.0
  scripts/tools/digest.sh --row tt-stack v0.1.0 rvocs-vllm-tt-amd64:v0.1.0

The image digest is taken from the local docker image when it exists, otherwise
from the registry (RVOCS_REGISTRY), so no pull is needed for a published tag.
EOF
}

digest_of_image_local() { # <name:tag> -> digest, non-zero when not local
  local ref="$1" d
  docker image inspect "$ref" >/dev/null 2>&1 || return 1
  d=$(docker image inspect "$ref" --format '{{range .RepoDigests}}{{println .}}{{end}}' 2>/dev/null \
      | sed -n 's/.*@\(sha256:[0-9a-f]\{64\}\)$/\1/p' | sed -n '1p')
  [ -n "$d" ] || d=$(docker image inspect "$ref" --format '{{.Id}}' 2>/dev/null)
  printf '%s' "$d"
}

# RVOCS_REGISTRY is "<host>/<namespace>" (e.g. swr.../cloud-mdgx); the registry
# API wants https://<host>/v2/<namespace>/<repo>/manifests/<tag>.
registry_split() {
  local reg="${RVOCS_REGISTRY%/}"
  reg="${reg#https://}"; reg="${reg#http://}"
  REG_HOST="${reg%%/*}"
  REG_NS=""
  case "$reg" in */*) REG_NS="${reg#*/}/" ;; esac
}

digest_of_image_registry() { # <name:tag> -> digest or empty
  local ref="$1" repo tag url hdr body digest realm service tok
  registry_split
  repo="${ref%:*}"; tag="${ref##*:}"
  url="https://$REG_HOST/v2/${REG_NS}${repo}/manifests/$tag"
  hdr=$(mktemp); body=$(mktemp)

  curl -sS --max-time 20 -o "$body" -D "$hdr" -H "Accept: $ACCEPT" "$url" >/dev/null 2>&1 || true
  digest=$(tr -d '\r' < "$hdr" | sed -n 's/^[Dd]ocker-[Cc]ontent-[Dd]igest: *//p' | tail -1)

  if [ -z "$digest" ]; then
    realm=$(tr -d '\r' < "$hdr" | sed -n 's/.*realm="\([^"]*\)".*/\1/p' | head -1)
    service=$(tr -d '\r' < "$hdr" | sed -n 's/.*service="\([^"]*\)".*/\1/p' | head -1)
    if [ -n "$realm" ]; then
      tok=$(curl -sS --max-time 20 "${realm%/}?service=${service:-dockyard}&scope=repository:${REG_NS}${repo}:pull" 2>/dev/null \
            | sed -n 's/.*"token":"\([^"]*\)".*/\1/p' | head -1 || true)
      if [ -n "$tok" ]; then
        curl -sS --max-time 20 -o /dev/null -D "$hdr" -H "Authorization: Bearer $tok" -H "Accept: $ACCEPT" \
          "$url" >/dev/null 2>&1 || true
        digest=$(tr -d '\r' < "$hdr" | sed -n 's/^[Dd]ocker-[Cc]ontent-[Dd]igest: *//p' | tail -1)
      fi
    fi
  fi

  rm -f "$hdr" "$body"
  printf '%s' "$digest"
}

row_target=""; row_version=""
case "${1:-}" in
  ''|-h|--help) usage; exit 0 ;;
  --row)
    [ $# -ge 4 ] || { usage; exit 2; }
    row_target="$2"; row_version="$3"; shift 3 ;;
esac

[ $# -ge 1 ] || { usage; exit 2; }

status=0
for art in "$@"; do
  if [ -f "$art" ]; then
    dg="sha256:$(sha256sum "$art" | cut -d' ' -f1)"
  elif [ ! -e "$art" ] && { case "$art" in *.deb) true ;; *) false ;; esac; }; then
    warn "file not found: $art"
    status=1; continue
  elif dg=$(digest_of_image_local "$art"); then
    :
  else
    dg=$(digest_of_image_registry "$art")
    if [ -z "$dg" ]; then
      warn "no digest for $art: not a file, no local image, and the tag is missing in $RVOCS_REGISTRY"
      status=1; continue
    fi
  fi

  if [ -n "$row_target" ]; then
    printf '%s\t%s\t%s\t%s\n' "$row_target" "$row_version" "$art" "$dg" | render_tsv
  else
    printf '%s\t%s\n' "$art" "$dg" | render_tsv
  fi
done

exit "$status"
