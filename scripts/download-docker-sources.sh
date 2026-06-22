#!/usr/bin/env bash

set -euo pipefail

SOURCE_DIR="${SOURCE_DIR:-.client-sources}"

RETH_REPO="${RETH_REPO:-https://github.com/paradigmxyz/reth-oss.git}"
RETH_REF="${RETH_REF:-ssz-engine-api-test}"
PRYSM_REPO="${PRYSM_REPO:-https://github.com/syjn99/prysm.git}"
PRYSM_REF="${PRYSM_REF:-prototype/ssz-over-http}"
ERIGON_REPO="${ERIGON_REPO:-https://github.com/erigontech/erigon.git}"
ERIGON_REF="${ERIGON_REF:-yperbasis/engine-ssz-793}"

sync_repo() {
  local name=$1 repo=$2 ref=$3 directory="$SOURCE_DIR/$1"
  if [[ -d "$directory/.git" ]]; then
    echo "Updating $name ($ref)"
    git -C "$directory" fetch --depth 1 origin "$ref"
    git -C "$directory" checkout --detach FETCH_HEAD
  elif [[ -e "$directory" ]]; then
    echo "$directory exists but is not a Git repository" >&2
    exit 1
  else
    echo "Downloading $name ($ref)"
    git clone --depth 1 --branch "$ref" "$repo" "$directory"
  fi
}

mkdir -p "$SOURCE_DIR"
sync_repo reth-oss "$RETH_REPO" "$RETH_REF"
sync_repo prysm "$PRYSM_REPO" "$PRYSM_REF"
sync_repo erigon "$ERIGON_REPO" "$ERIGON_REF"

echo "Client sources are ready under $SOURCE_DIR/"
