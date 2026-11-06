#!/usr/bin/env bash
# action: deploy - start the inference container
#
# The image tag is taken from RELEASES.list (newest artifact matching --arch),
# with the derived local build name as a fallback.
#
# Devices and mounts are fixed per accelerator type (matching each sub-repo README):
#   Tenstorrent : /dev/tenstorrent + /dev/hugepages-1G + a model cache volume
#   AMD         : /dev/kfd + /dev/dri + render/video groups + seccomp=unconfined
#                 + read-only /models
#
# usage: bash scripts/actions/deploy.sh <target> [-- extra container args]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

TARGET="${1:?usage: deploy.sh <target> [-- container args]}"; shift || true
EXTRA=("$@")

image_exists_or_warn() {
  local tag="$1"
  image_exists "$tag" && return 0
  warn "no local image $tag"
  warn "  pull : ./rvocs.sh --target $TARGET --arch $ARCH --download"
  warn "  build: ./rvocs.sh --target $TARGET --arch $ARCH --build"
  return 0
}

case "$TARGET" in
  tt-stack)
    tag=$(published_image_for tt-stack "$ARCH")
    image_exists_or_warn "$tag"
    cmd=(docker run --rm
         --ipc host
         --publish "$DEPLOY_PORT:8000"
         --device /dev/tenstorrent
         --mount "type=bind,src=/dev/hugepages-1G,dst=/dev/hugepages-1G"
         --volume "$TT_CACHE_VOLUME:/home/container_app_user/cache_root"
         "$tag"
         --model "$TT_DEPLOY_MODEL"
         --tt-device "$TT_DEPLOY_DEVICE")
    ;;

  therock)
    tag=$(published_image_for therock "$ARCH")
    image_exists_or_warn "$tag"
    cmd=(docker run -d
         --name "$AMDG_CONTAINER_NAME"
         --network=host
         --ipc=host
         --device=/dev/kfd
         --device=/dev/dri
         --group-add video
         --group-add render
         --security-opt seccomp=unconfined
         -v "$AMDG_MODELS_DIR:/models:ro"
         -e "MODEL_PATH=$AMDG_MODELS_DIR/$AMDG_DEPLOY_MODEL"
         "$tag")
    ;;

  *)
    die "deploy does not support $TARGET. $(target_hint "$TARGET" deploy)"
    ;;
esac

cmd+=("${EXTRA[@]}")

echo
log "container start command ($TARGET / $ARCH):"
echo
printf '  %s\n' "$(quote_cmd "${cmd[@]}")"
echo

# For AMD targets, refuse to overwrite an existing container with the same name
if [ "$TARGET" = therock ] && have_cmd docker \
   && docker ps -a --format '{{.Names}}' | grep -qx "$AMDG_CONTAINER_NAME"; then
  die "a container named $AMDG_CONTAINER_NAME already exists.
       reuse: docker start $AMDG_CONTAINER_NAME
       replace: docker rm -f $AMDG_CONTAINER_NAME and re-run"
fi

log "starting container..."
"${cmd[@]}"
log "started."
case "$TARGET" in
  tt-stack) log "endpoint: http://127.0.0.1:$DEPLOY_PORT/v1 (model $TT_DEPLOY_MODEL, device $TT_DEPLOY_DEVICE)" ;;
  therock)  log "logs: docker logs -f $AMDG_CONTAINER_NAME (model path $AMDG_MODELS_DIR/$AMDG_DEPLOY_MODEL)" ;;
esac
