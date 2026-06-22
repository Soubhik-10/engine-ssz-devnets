#!/usr/bin/env bash

set -euo pipefail

RETH_SERVICE="${RETH_SERVICE:-el-1-reth-prysm}"
ERIGON_SERVICE="${ERIGON_SERVICE:-el-5-erigon-prysm}"
FROM_BLOCK="${FROM_BLOCK:-}"
COUNT="${COUNT:-10}"
SECONDS_PER_SLOT="${SECONDS_PER_SLOT:-6}"
SLOTS_PER_EPOCH="${SLOTS_PER_EPOCH:-32}"
OUTPUT_DIR="${OUTPUT_DIR:-engine-ssz-comparison}"
FIXTURE_DIR="${FIXTURE_DIR:-engine-ssz-fixtures}"
FORKS=(paris shanghai cancun prague osaka amsterdam)
BLOB_VERSIONS=(v1 v2 v3 v4)

if [[ -t 1 ]]; then
  RED=$'\033[31m'
  GREEN=$'\033[32m'
  YELLOW=$'\033[33m'
  CYAN=$'\033[36m'
  RESET=$'\033[0m'
else
  RED=''
  GREEN=''
  YELLOW=''
  CYAN=''
  RESET=''
fi

temporary_dir=$(mktemp -d)
trap 'rm -rf "$temporary_dir"' EXIT
mkdir -p "$OUTPUT_DIR"

container_for_service() {
  local service=$1 containers
  containers=$(docker ps --filter "name=${service}--" --format '{{.ID}}')
  if [[ -z "$containers" ]]; then
    echo "No running Docker container found for $service" >&2
    exit 1
  fi
  if [[ $(printf '%s\n' "$containers" | wc -l) -ne 1 ]]; then
    echo "Multiple running containers matched $service:" >&2
    printf '%s\n' "$containers" >&2
    exit 1
  fi
  printf '%s' "$containers"
}

published_port() {
  local container=$1 internal_port=$2 mapping
  mapping=$(docker port "$container" "$internal_port/tcp" | head -n 1)
  if [[ -z "$mapping" ]]; then
    echo "Container $container does not publish $internal_port/tcp" >&2
    exit 1
  fi
  printf '%s' "${mapping##*:}"
}

b64url() {
  openssl base64 -A | tr '+/' '-_' | tr -d '='
}

fresh_jwt() {
  local header payload unsigned signature
  header=$(printf '{"alg":"HS256","typ":"JWT"}' | b64url)
  payload=$(printf '{"iat":%s}' "$(date +%s)" | b64url)
  unsigned="$header.$payload"
  signature=$(printf '%s' "$unsigned" |
    openssl dgst -sha256 -mac HMAC -macopt "hexkey:$JWT_SECRET" -binary |
    b64url)
  printf '%s' "$unsigned.$signature"
}

content_type() {
  awk 'BEGIN { IGNORECASE=1 } /^content-type:/ {
    sub(/^[^:]*:[[:space:]]*/, ""); sub(/\r$/, ""); value=$0
  } END { print value }' "$1"
}

print_json() {
  local file=$1
  if command -v jq >/dev/null 2>&1; then
    jq . "$file" 2>/dev/null || cat "$file"
  else
    cat "$file"
    echo
  fi
}

request_endpoint() {
  local client=$1 port=$2 method=$3 path=$4 expected_type=$5 output_name=$6 input=${7:-}
  local headers="$OUTPUT_DIR/${client}-${output_name}.headers"
  local body="$OUTPUT_DIR/${client}-${output_name}"
  local status type token
  local args=(-sS -X "$method" -D "$headers" -o "$body")
  token=$(fresh_jwt)
  args+=(-H "Authorization: Bearer $token" -H "Accept: $expected_type")
  if [[ "$method" == POST ]]; then
    args+=(-H 'Content-Type: application/octet-stream' --data-binary "@$input")
  fi
  status=$(curl "${args[@]}" --write-out '%{http_code}' "http://127.0.0.1:${port}${path}")
  type=$(content_type "$headers")
  printf '%-7s %-48s HTTP=%s TYPE=%s\n' "$client" "$path" "$status" "$type"
  if [[ "$status" != 200 || "$type" != "$expected_type"* ]]; then
    printf '%sFAIL: %s returned HTTP=%s TYPE=%s%s\n' \
      "$RED" "$client $path" "$status" "$type" "$RESET" >&2
    printf '%s  Response body: %s%s\n' "$RED" "$body" "$RESET" >&2
    return 1
  fi
}

compare_binary_pair() {
  local label=$1 reth_file=$2 erigon_file=$3
  sha256sum "$reth_file" "$erigon_file"
  if cmp -s "$reth_file" "$erigon_file"; then
    printf '%sMATCH: %s%s\n' "$GREEN" "$label" "$RESET"
  else
    printf '%sMISMATCH: %s%s\n' "$RED" "$label" "$RESET" >&2
    return 1
  fi
}

run_binary_pair() {
  local method=$1 path=$2 output_name=$3 input=${4:-}
  local pair_failed=0
  request_endpoint reth "$reth_port" "$method" "$path" application/octet-stream "$output_name" "$input" || pair_failed=1
  request_endpoint erigon "$erigon_port" "$method" "$path" application/octet-stream "$output_name" "$input" || pair_failed=1
  if [[ $pair_failed -eq 0 ]]; then
    compare_binary_pair "$path" "$OUTPUT_DIR/reth-$output_name" "$OUTPUT_DIR/erigon-$output_name" || pair_failed=1
  fi
  failures=$((failures + pair_failed))
  echo
}

skip_fixture() {
  local route=$1 fixture=$2
  printf '%sSKIP    %-48s missing %s%s\n' "$YELLOW" "$route" "$fixture" "$RESET"
  skipped=$((skipped + 1))
}

fork_epoch() {
  case "$1" in
    paris) printf '0' ;;
    shanghai) printf '0' ;;
    cancun) printf '1' ;;
    prague) printf '2' ;;
    osaka) printf '3' ;;
    amsterdam) printf '4' ;;
    *) return 1 ;;
  esac
}

fork_has_block_window() {
  local fork=$1 activation next_activation
  activation=$(fork_epoch "$fork")
  case "$fork" in
    paris) next_activation=$(fork_epoch shanghai) ;;
    shanghai) next_activation=$(fork_epoch cancun) ;;
    cancun) next_activation=$(fork_epoch prague) ;;
    prague) next_activation=$(fork_epoch osaka) ;;
    osaka) next_activation=$(fork_epoch amsterdam) ;;
    amsterdam) return 0 ;;
  esac
  ((next_activation > activation))
}

fork_is_active() {
  local activation
  activation=$(fork_epoch "$1")
  [[ "$current_epoch" -ge "$activation" ]]
}

skip_future_fork() {
  local route=$1 fork=$2 activation
  activation=$(fork_epoch "$fork")
  printf '%sSKIP    %-48s %s activates at epoch %s; current epoch is %s%s\n' \
    "$YELLOW" "$route" "$fork" "$activation" "$current_epoch" "$RESET"
  skipped=$((skipped + 1))
}

skip_empty_fork_window() {
  local route=$1 fork=$2
  printf '%sSKIP    %-48s %s has no block window in this fork schedule%s\n' \
    "$YELLOW" "$route" "$fork" "$RESET"
  skipped=$((skipped + 1))
}

rpc_call() {
  local method=$1 params=$2
  curl -sS -H 'Content-Type: application/json' \
    --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$method\",\"params\":$params}" \
    "http://127.0.0.1:$reth_rpc_port"
}

write_hash_list_request() {
  local hash=$1 output=$2
  if [[ ! "$hash" =~ ^0x[[:xdigit:]]{64}$ ]]; then
    echo "Invalid Bytes32 hash: $hash" >&2
    return 1
  fi
  # Single-field SSZ container: offset 4, followed by List[Bytes32].
  printf '\x04\x00\x00\x00' > "$output"
  printf '%s' "${hash#0x}" | xxd -r -p >> "$output"
}

first_block_for_fork() {
  local fork=$1 activation target low=1 high=$latest_block_number mid response timestamp_hex timestamp
  activation=$(fork_epoch "$fork")
  target=$((genesis_timestamp + activation * SLOTS_PER_EPOCH * SECONDS_PER_SLOT))

  while ((low < high)); do
    mid=$(((low + high) / 2))
    printf -v block_hex '0x%x' "$mid"
    response=$(rpc_call eth_getBlockByNumber "[\"$block_hex\",false]")
    timestamp_hex=$(printf '%s' "$response" | sed -n 's/.*"timestamp":"\(0x[0-9a-fA-F]*\)".*/\1/p')
    if [[ -z "$timestamp_hex" ]]; then
      low=$((mid + 1))
      continue
    fi
    timestamp=$((16#${timestamp_hex#0x}))
    if ((timestamp < target)); then
      low=$((mid + 1))
    else
      high=$mid
    fi
  done

  printf -v block_hex '0x%x' "$low"
  response=$(rpc_call eth_getBlockByNumber "[\"$block_hex\",false]")
  timestamp_hex=$(printf '%s' "$response" | sed -n 's/.*"timestamp":"\(0x[0-9a-fA-F]*\)".*/\1/p')
  [[ -n "$timestamp_hex" ]] || return 1
  timestamp=$((16#${timestamp_hex#0x}))
  ((timestamp >= target)) || return 1
  printf '%s' "$low"
}

block_hash_request() {
  local block_number=$1 output=$2 block_hex response block_hash
  printf -v block_hex '0x%x' "$block_number"
  response=$(rpc_call eth_getBlockByNumber "[\"$block_hex\",false]")
  block_hash=$(printf '%s' "$response" | sed -n 's/.*"hash":"\(0x[0-9a-fA-F]*\)".*/\1/p')
  if [[ -z "$block_hash" ]]; then
    echo "No block hash found for block $block_number" >&2
    return 1
  fi
  write_hash_list_request "$block_hash" "$output"
}

find_blob_versioned_hash() {
  local latest_response latest_hex latest block_hex block response hash lower_bound
  latest_response=$(rpc_call eth_blockNumber '[]')
  latest_hex=$(printf '%s' "$latest_response" | sed -n 's/.*"result":"\(0x[0-9a-fA-F]*\)".*/\1/p')
  if [[ -z "$latest_hex" ]]; then
    return 1
  fi
  latest=$((16#${latest_hex#0x}))
  lower_bound=$((latest > 256 ? latest - 256 : 0))
  for ((block=latest; block>=lower_bound; block--)); do
    printf -v block_hex '0x%x' "$block"
    response=$(rpc_call eth_getBlockByNumber "[\"$block_hex\",true]")
    hash=$(printf '%s' "$response" |
      grep -oE '"blobVersionedHashes":\["0x[[:xdigit:]]{64}"' |
      grep -oE '0x[[:xdigit:]]{64}' | head -n 1 || true)
    if [[ -n "$hash" ]]; then
      printf '%s' "$hash"
      return 0
    fi
  done
  return 1
}

reth_container=$(container_for_service "$RETH_SERVICE")
erigon_container=$(container_for_service "$ERIGON_SERVICE")
reth_port=$(published_port "$reth_container" 8551)
erigon_port=$(published_port "$erigon_container" 8551)
reth_rpc_port=$(published_port "$reth_container" 8545)

docker cp "$reth_container:/jwt/jwtsecret" "$temporary_dir/jwt.hex" >/dev/null
JWT_SECRET=$(tr -d '\r\n[:space:]' < "$temporary_dir/jwt.hex")
JWT_SECRET=${JWT_SECRET#0x}
if [[ ! "$JWT_SECRET" =~ ^[[:xdigit:]]{64}$ ]]; then
  echo "JWT secret is not a 32-byte hexadecimal value" >&2
  exit 1
fi

genesis_json=$(rpc_call eth_getBlockByNumber '["0x0",false]')
latest_json=$(rpc_call eth_getBlockByNumber '["latest",false]')
latest_number_json=$(rpc_call eth_blockNumber '[]')
genesis_hex=$(printf '%s' "$genesis_json" | sed -n 's/.*"timestamp":"\(0x[0-9a-fA-F]*\)".*/\1/p')
latest_hex=$(printf '%s' "$latest_json" | sed -n 's/.*"timestamp":"\(0x[0-9a-fA-F]*\)".*/\1/p')
latest_number_hex=$(printf '%s' "$latest_number_json" | sed -n 's/.*"result":"\(0x[0-9a-fA-F]*\)".*/\1/p')
if [[ -z "$genesis_hex" || -z "$latest_hex" || -z "$latest_number_hex" ]]; then
  echo 'Could not derive the chain epoch and block height from EL JSON-RPC.' >&2
  exit 1
fi
genesis_timestamp=$((16#${genesis_hex#0x}))
latest_timestamp=$((16#${latest_hex#0x}))
latest_block_number=$((16#${latest_number_hex#0x}))
detected_epoch=$(((latest_timestamp - genesis_timestamp) / (SECONDS_PER_SLOT * SLOTS_PER_EPOCH)))
current_epoch=${CURRENT_EPOCH:-$detected_epoch}

echo "Reth:   $RETH_SERVICE at 127.0.0.1:$reth_port"
echo "Erigon: $ERIGON_SERVICE at 127.0.0.1:$erigon_port"
echo "Current epoch: $current_epoch"
echo

failures=0
skipped=0

printf '%s== Identification (JSON) ==%s\n' "$CYAN" "$RESET"
for endpoint in capabilities identity; do
  request_endpoint reth "$reth_port" GET "/engine/v2/$endpoint" application/json "$endpoint.json" || failures=$((failures + 1))
  echo 'Reth JSON:'
  print_json "$OUTPUT_DIR/reth-$endpoint.json"
  request_endpoint erigon "$erigon_port" GET "/engine/v2/$endpoint" application/json "$endpoint.json" || failures=$((failures + 1))
  echo 'Erigon JSON:'
  print_json "$OUTPUT_DIR/erigon-$endpoint.json"
  echo
done

printf '%s== Payload Bodies By Range ==%s\n' "$CYAN" "$RESET"
for fork in "${FORKS[@]}"; do
  if ! fork_has_block_window "$fork"; then
    skip_empty_fork_window "/engine/v2/$fork/bodies" "$fork"
    continue
  fi
  if ! fork_is_active "$fork"; then
    skip_future_fork "/engine/v2/$fork/bodies" "$fork"
    continue
  fi
  activation=$(fork_epoch "$fork")
  if [[ -n "$FROM_BLOCK" ]]; then
    range_from=$FROM_BLOCK
  elif ! range_from=$(first_block_for_fork "$fork"); then
    printf '%sSKIP: no live block found for %s.%s\n' "$YELLOW" "$fork" "$RESET"
    skipped=$((skipped + 1))
    continue
  fi
  run_binary_pair GET "/engine/v2/$fork/bodies?from=$range_from&count=$COUNT" "$fork-bodies-range.ssz"
done

printf '%s== Payload Bodies By Hash (live block hash) ==%s\n' "$CYAN" "$RESET"
for fork in "${FORKS[@]}"; do
  if ! fork_has_block_window "$fork"; then
    skip_empty_fork_window "/engine/v2/$fork/bodies/hash" "$fork"
    continue
  fi
  if ! fork_is_active "$fork"; then
    skip_future_fork "/engine/v2/$fork/bodies/hash" "$fork"
    continue
  fi
  if [[ -n "$FROM_BLOCK" ]]; then
    hash_block=$FROM_BLOCK
  elif ! hash_block=$(first_block_for_fork "$fork"); then
    printf '%sSKIP: no live block found for %s.%s\n' "$YELLOW" "$fork" "$RESET"
    skipped=$((skipped + 1))
    continue
  fi
  hash_request="$temporary_dir/$fork-bodies-hash-request.ssz"
  if block_hash_request "$hash_block" "$hash_request"; then
    run_binary_pair POST "/engine/v2/$fork/bodies/hash" "$fork-bodies-hash.ssz" "$hash_request"
  else
    failures=$((failures + 1))
  fi
done

printf '%s== Blob Retrieval (live versioned hash) ==%s\n' "$CYAN" "$RESET"
blob_request="$temporary_dir/blob-versioned-hash-request.ssz"
if blob_hash=$(find_blob_versioned_hash); then
  write_hash_list_request "$blob_hash" "$blob_request"
  echo "Using blob versioned hash: $blob_hash"
else
  blob_hash=''
  printf '%sSKIP: no blob transaction found in the latest 256 blocks.%s\n' "$YELLOW" "$RESET"
fi
for index in "${!BLOB_VERSIONS[@]}"; do
  version=${BLOB_VERSIONS[$index]}
  blob_fork=${FORKS[$((index + 2))]}
  if ! fork_is_active "$blob_fork"; then
    skip_future_fork "/engine/v2/blobs/$version" "$blob_fork"
    continue
  fi
  if [[ -n "$blob_hash" ]]; then
    run_binary_pair POST "/engine/v2/blobs/$version" "blobs-$version.ssz" "$blob_request"
  else
    skipped=$((skipped + 1))
  fi
done

printf '%s== Payload Submission ==%s\n' "$CYAN" "$RESET"
for fork in "${FORKS[@]}"; do
  if ! fork_has_block_window "$fork"; then
    skip_empty_fork_window "/engine/v2/$fork/payloads" "$fork"
    continue
  fi
  if ! fork_is_active "$fork"; then
    skip_future_fork "/engine/v2/$fork/payloads" "$fork"
    continue
  fi
  fixture="$FIXTURE_DIR/payloads/$fork.ssz"
  if [[ -f "$fixture" ]]; then
    run_binary_pair POST "/engine/v2/$fork/payloads" "$fork-payload-submit.ssz" "$fixture"
  else
    skip_fixture "/engine/v2/$fork/payloads" "$fixture"
  fi
done
echo

printf '%s== Forkchoice Updated ==%s\n' "$CYAN" "$RESET"
for fork in "${FORKS[@]}"; do
  if ! fork_has_block_window "$fork"; then
    skip_empty_fork_window "/engine/v2/$fork/forkchoice" "$fork"
    continue
  fi
  if ! fork_is_active "$fork"; then
    skip_future_fork "/engine/v2/$fork/forkchoice" "$fork"
    continue
  fi
  fixture="$FIXTURE_DIR/forkchoice/$fork.ssz"
  if [[ -f "$fixture" ]]; then
    run_binary_pair POST "/engine/v2/$fork/forkchoice" "$fork-forkchoice.ssz" "$fixture"
  else
    skip_fixture "/engine/v2/$fork/forkchoice" "$fixture"
  fi
done
echo

printf '%s== Get Payload ==%s\n' "$CYAN" "$RESET"
for fork in "${FORKS[@]}"; do
  if ! fork_has_block_window "$fork"; then
    skip_empty_fork_window "/engine/v2/$fork/payloads/{payloadId}" "$fork"
    continue
  fi
  if ! fork_is_active "$fork"; then
    skip_future_fork "/engine/v2/$fork/payloads/{payloadId}" "$fork"
    continue
  fi
  id_file="$FIXTURE_DIR/payload-ids/$fork.txt"
  if [[ -s "$id_file" ]]; then
    payload_id=$(tr -d '\r\n[:space:]' < "$id_file")
    run_binary_pair GET "/engine/v2/$fork/payloads/$payload_id" "$fork-get-payload.ssz"
  else
    skip_fixture "/engine/v2/$fork/payloads/{payloadId}" "$id_file"
  fi
done

echo
if [[ $failures -gt 0 ]]; then
  printf '%sCompleted with %s comparison failure(s) and %s skip(s).%s\n' \
    "$RED" "$failures" "$skipped" "$RESET"
else
  printf '%sCompleted with no comparison failures and %s skip(s).%s\n' \
    "$GREEN" "$skipped" "$RESET"
fi
echo "Responses and headers: $OUTPUT_DIR/"
echo "Fixtures: $FIXTURE_DIR/"
exit "$failures"
