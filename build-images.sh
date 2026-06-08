#!/bin/bash
set -euo pipefail

#
# Build and push ZTWIM demo container images to quay.io
#
# Prerequisites:
#   - podman installed
#   - logged in to quay.io: podman login quay.io
#
# Usage:
#   ./build-images.sh              # build and push both images
#   ./build-images.sh simple       # build and push only ztwim-simple
#   ./build-images.sh oidc         # build and push only ztwim-oidc
#

REGISTRY="${REGISTRY:-quay.io}"
ORG="${ORG:-tssc_demos}"
TAG="${TAG:-latest}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

log() { echo ">>> $*"; }

build_and_push() {
  local name="$1" src_dir="$2"
  local full_image="${REGISTRY}/${ORG}/${name}:${TAG}"

  log "Building ${full_image} from ${src_dir}/"
  podman build -t "$full_image" -f "${src_dir}/Containerfile" "$src_dir"

  log "Pushing ${full_image}"
  podman push "$full_image"

  log "Done: ${full_image}"
  echo ""
}

TARGET="${1:-all}"

if [ "$TARGET" = "all" ] || [ "$TARGET" = "simple" ]; then
  build_and_push "ztwim-simple" "${SCRIPT_DIR}/ztwim-simple/src"
fi

if [ "$TARGET" = "all" ] || [ "$TARGET" = "oidc" ]; then
  build_and_push "ztwim-oidc" "${SCRIPT_DIR}/ztwim-oidc/src"
fi

log "=========================================="
log "  Images built and pushed"
log "=========================================="
log ""
log "To use in deploy scripts, set:"
log "  export IMAGE_REGISTRY=${REGISTRY}/${ORG}"
log ""
log "Or update the deployment YAMLs:"
log "  ztwim-simple: ${REGISTRY}/${ORG}/ztwim-simple:${TAG}"
log "  ztwim-oidc:   ${REGISTRY}/${ORG}/ztwim-oidc:${TAG}"
