#!/usr/bin/env bash

set -uo pipefail

ENCLAVE="${ENCLAVE:-engine-ssz}"
KURTOSIS="${KURTOSIS:-kurtosis}"
LOG_DIR="${LOG_DIR:-logs/$ENCLAVE}"

mkdir -p "$LOG_DIR"
inspect_file="$LOG_DIR/_enclave-inspect.txt"

if ! "$KURTOSIS" enclave inspect --full-uuids "$ENCLAVE" > "$inspect_file"; then
  echo "Could not inspect Kurtosis enclave '$ENCLAVE'." >&2
  exit 1
fi

mapfile -t services < <(
  awk '
    /User Services/ { in_services=1; next }
    in_services && length($1) == 32 && $1 ~ /^[[:xdigit:]]+$/ { print $2 }
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
  printf '%-48s -> %s\n' "$service" "$output"
  if ! "$KURTOSIS" service logs "$ENCLAVE" "$service" > "$output" 2>&1; then
    echo "Failed to collect $service" >&2
    failures=$((failures + 1))
  fi
done

echo
echo "Collected $((${#services[@]} - failures))/${#services[@]} service logs."
echo "Enclave inspection: $inspect_file"
exit "$failures"
