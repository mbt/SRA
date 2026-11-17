#!/bin/sh
# Print harness binary sizes + sha256. Gate: every binary < 300 KiB.
# Usage: scripts/size-report.sh [dist-dir]
set -eu
DIR="${1:-dist}"
BUDGET_KB=300
fail=0
printf "%-20s %10s %64s %s\n" "binary" "size" "sha256" "status"
for f in "$DIR"/harness-*; do
  [ -e "$f" ] || { echo "no binaries in $DIR — run scripts/build-harness.sh"; exit 1; }
  bytes=$(wc -c < "$f" | tr -d ' ')
  kb=$(( (bytes + 1023) / 1024 ))
  sha=$(shasum -a 256 "$f" 2>/dev/null | cut -d' ' -f1 || sha256sum "$f" | cut -d' ' -f1)
  if [ "$kb" -le "$BUDGET_KB" ]; then st="OK"; else st="OVER BUDGET"; fail=1; fi
  printf "%-20s %7d KB %64s %s\n" "$(basename "$f")" "$kb" "$sha" "$st"
done
exit $fail
