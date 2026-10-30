#!/usr/bin/env bash
# The live moment: drop a held-back file into landing/bronze/ and let Snowpipe pick it up (about a minute).
#   bash azure/04_drop_held_back.sh portal_sla_events.csv         # drop one file
#   bash azure/04_drop_held_back.sh --reset portal_sla_events.csv # remove it again, to rehearse once more
# After --reset, also run:  TRUNCATE TABLE EDW_BRONZE.RAW.PORTAL_SLA_EVENTS;  (the pipe remembers the file name, so
# re-dropping the same name is skipped until the pipe's history expires; use ALTER PIPE ... REFRESH or a new file name).
set -euo pipefail
export MSYS_NO_PATHCONV=1
HERE="$(cd "$(dirname "$0")/.." && { pwd -W 2>/dev/null || pwd; })"   # Windows-style path: az is a Windows program
RG="${RG:-rg-edw-demo}"; SA="${SA:-edwdemolanding}"; CONTAINER="${CONTAINER:-landing}"
MODE=drop; [ "${1:-}" = "--reset" ] && { MODE=reset; shift; }
NAME="${1:?file name in data/bronze, e.g. portal_sla_events.csv}"
export AZURE_STORAGE_ACCOUNT="$SA" AZURE_STORAGE_KEY="$(az storage account keys list -g "$RG" -n "$SA" --query '[0].value' -o tsv)"
if [ "$MODE" = drop ]; then
  az storage blob upload -c "$CONTAINER" -n "bronze/$NAME" -f "$HERE/data/bronze/$NAME" --overwrite --auth-mode key -o none
  echo "dropped bronze/$NAME at $(date +%H:%M:%S). Watch: SELECT SYSTEM\$PIPE_STATUS('EDW_BRONZE.LANDING.PIPE_<TABLE>');"
else
  az storage blob delete -c "$CONTAINER" -n "bronze/$NAME" --auth-mode key -o none
  echo "removed bronze/$NAME"
fi
