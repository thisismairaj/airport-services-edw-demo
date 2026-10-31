#!/usr/bin/env bash
# Put the demo data in the ADLS landing container (landing/bronze, landing/bad_files), except the
# files in HOLD_BACK: those stay out so they can be dropped live (rehearsal or demo) with 04_drop_held_back.sh.
#   bash azure/03_upload.sh
#   HOLD_BACK="portal_sla_events.csv" bash azure/03_upload.sh      # choose other files to hold back
# Run it BEFORE the Snowpipe pipes exist (sql/02b_snowpipe.sql). Uploading raises BlobCreated events that Event Grid
# puts in the queue; a pipe created afterwards would load those files a second time on top of the initial COPY, so this
# script clears the queue at the end.
set -euo pipefail
export MSYS_NO_PATHCONV=1
HERE="$(cd "$(dirname "$0")/.." && { pwd -W 2>/dev/null || pwd; })"   # Windows-style path: az is a Windows program
DATA="$HERE/data"
RG="${RG:-rg-edw-demo}"; SA="${SA:-edwdemolanding}"; CONTAINER="${CONTAINER:-landing}"; QUEUE="${QUEUE:-snowpipe-events}"
HOLD_BACK="${HOLD_BACK-portal_sla_events.csv sita_messages.csv}"   # HOLD_BACK="" holds nothing back   # bronze files kept out of the first load
export AZURE_STORAGE_ACCOUNT="$SA" AZURE_STORAGE_KEY="$(az storage account keys list -g "$RG" -n "$SA" --query '[0].value' -o tsv)"

n=0; held=0
for f in "$DATA"/bronze/*.csv; do
  name="$(basename "$f")"
  if [[ " $HOLD_BACK " == *" $name "* ]]; then echo "held back: $name"; held=$((held + 1)); continue; fi
  az storage blob upload -c "$CONTAINER" -n "bronze/$name" -f "$f" --overwrite --auth-mode key -o none; n=$((n + 1))
done
echo "bronze: $n uploaded, $held held back"
az storage blob upload-batch -d "$CONTAINER" --destination-path bad_files -s "$DATA/bad_files" --pattern "*.csv" --overwrite --auth-mode key -o none
echo "bad_files uploaded"
sleep 20   # let Event Grid deliver the BlobCreated events, then drop them: only files that arrive later should be loaded by the pipes
az storage message clear -q "$QUEUE" --auth-mode key -o none
echo "queue $QUEUE cleared. Container now holds: $(az storage blob list -c "$CONTAINER" --auth-mode key --query 'length(@)' -o tsv) blobs"
