#!/usr/bin/env bash

set -euo pipefail

SOURCE_DIR="${SOURCE_DIR:-.client-sources}"
PLATFORM="${PLATFORM:-linux/amd64}"
BAZEL="${BAZEL:-bazel}"
PRYSM_BAZEL_CONFIG="${PRYSM_BAZEL_CONFIG:-linux_amd64}"

RETH_IMAGE="${RETH_IMAGE:-reth:ssz-engine-api-test}"
ERIGON_IMAGE="${ERIGON_IMAGE:-test/erigon:engine-ssz-793}"
PRYSM_BN_IMAGE="${PRYSM_BN_IMAGE:-prysm-bn-custom-image:engine-ssz}"
PRYSM_VC_IMAGE="${PRYSM_VC_IMAGE:-prysm-vc-custom-image:engine-ssz}"

require_source() {
  if [[ ! -d "$1" ]]; then
    echo "Missing source directory $1; run 'make download-docker-sources' first." >&2
    exit 1
  fi
}

require_source "$SOURCE_DIR/reth-oss"
require_source "$SOURCE_DIR/prysm"
require_source "$SOURCE_DIR/erigon"

echo "Building $RETH_IMAGE"
docker build --platform "$PLATFORM" -t "$RETH_IMAGE" "$SOURCE_DIR/reth-oss"

echo "Building $ERIGON_IMAGE"
docker build --platform "$PLATFORM" -t "$ERIGON_IMAGE" "$SOURCE_DIR/erigon"

if ! command -v "$BAZEL" >/dev/null 2>&1; then
  echo "Bazel is required to build the Prysm OCI images (BAZEL=$BAZEL)." >&2
  exit 1
fi

echo "Building $PRYSM_BN_IMAGE"
(
  cd "$SOURCE_DIR/prysm"
  "$BAZEL" run --config="$PRYSM_BAZEL_CONFIG" //cmd/beacon-chain:oci_image_tarball
)
docker tag gcr.io/offchainlabs/prysm/beacon-chain:latest "$PRYSM_BN_IMAGE"

echo "Building $PRYSM_VC_IMAGE"
(
  cd "$SOURCE_DIR/prysm"
  "$BAZEL" run --config="$PRYSM_BAZEL_CONFIG" //cmd/validator:oci_image_tarball
)
docker tag gcr.io/offchainlabs/prysm/validator:latest "$PRYSM_VC_IMAGE"

echo
docker image inspect \
  "$RETH_IMAGE" "$ERIGON_IMAGE" "$PRYSM_BN_IMAGE" "$PRYSM_VC_IMAGE" \
  --format '{{index .RepoTags 0}} {{.Os}}/{{.Architecture}}'
