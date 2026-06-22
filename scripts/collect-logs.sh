#!/usr/bin/env bash

set -uo pipefail

ENCLAVE="${ENCLAVE:-engine-ssz}"
KURTOSIS="${KURTOSIS:-kurtosis}"
LOG_DIR="${LOG_DIR:-logs/$ENCLAVE}"
INCLUDE_ALL="${INCLUDE_ALL:-0}"

mkdir -p "$LOG_DIR"
inspect_file="$LOG_DIR/_enclave-inspect.txt"
temporary_dir=$(mktemp -d)
trap 'rm -rf "$temporary_dir"' EXIT

if ! "$KURTOSIS" enclave inspect --full-uuids "$ENCLAVE" > "$inspect_file"; then
  echo "Could not inspect Kurtosis enclave '$ENCLAVE'." >&2
  exit 1
fi

mapfile -t services < <(
  awk -v include_all="$INCLUDE_ALL" '
    /User Services/ { in_services=1; next }
    in_services && length($1) == 32 && $1 ~ /^[[:xdigit:]]+$/ {
      if (include_all == 1 || $2 ~ /^(el|cl|vc)-/) print $2
    }
  ' "$inspect_file"
)

if [[ ${#services[@]} -eq 0 ]]; then
  echo "No user services found in enclave '$ENCLAVE'."
  echo "Inspect output: $inspect_file"
  exit 0
fi

echo "Collecting ${#services[@]} service logs into $LOG_DIR/"
failures=0

for service in "${services[@]}"; do
  safe_name=${service//\//_}
  output="$LOG_DIR/$safe_name.log"
  raw_output="$temporary_dir/$safe_name.log"
  printf '%-48s -> %s\n' "$service" "$output"
  if "$KURTOSIS" service logs --all "$ENCLAVE" "$service" > "$raw_output" 2>&1; then
    # Remove ANSI terminal styling before writing plain-text log files.
    sed $'s/\033\[[0-?]*[ -\/]*[@-~]//g' "$raw_output" > "$output"
  else
    sed $'s/\033\[[0-?]*[ -\/]*[@-~]//g' "$raw_output" > "$output"
    echo "Failed to collect $service" >&2
    failures=$((failures + 1))
  fi
done

echo
echo "Collected $((${#services[@]} - failures))/${#services[@]} service logs."
echo "Enclave inspection: $inspect_file"
exit "$failures"
