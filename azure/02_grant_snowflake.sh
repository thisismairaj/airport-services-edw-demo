#!/usr/bin/env bash
# After the one-time consent clicks (the two AZURE_CONSENT_URL links from sql/01b_adls_integration.sql), give each
# Snowflake app the one role it needs. Least privilege: read blobs in the container; read and delete queue messages.
#   bash azure/02_grant_snowflake.sh <AZURE_MULTI_TENANT_APP_NAME of INT_EDW_ADLS> <AZURE_MULTI_TENANT_APP_NAME of NINT_EDW_LANDING>
# Example: bash azure/02_grant_snowflake.sh 2t3ppksnowflakepacint_1793187408843 lfrhcjsnowflakepacint_1793187409035
set -euo pipefail
export MSYS_NO_PATHCONV=1
STORAGE_APP="${1:?name of the storage integration app}"; QUEUE_APP="${2:?name of the notification integration app}"
RG="${RG:-rg-edw-demo}"; SA="${SA:-edwdemolanding}"; CONTAINER="${CONTAINER:-landing}"; QUEUE="${QUEUE:-snowpipe-events}"
SA_ID="$(az storage account show -n "$SA" -g "$RG" --query id -o tsv)"

# Snowflake shows the app name as <prefix>_<number>; the enterprise app in Entra carries the prefix only.
sp_id() { az ad sp list --filter "startswith(displayName,'${1%%_*}')" --query "[0].id" -o tsv; }
assign() {   # assign <app name> <role> <scope>
  local oid; oid="$(sp_id "$1")"
  [ -n "$oid" ] || { echo "MISSING: no enterprise app '${1%%_*}' yet, open its consent link first ($2 not granted)." >&2; MISSING=1; return 0; }
  az role assignment create --assignee-object-id "$oid" --assignee-principal-type ServicePrincipal --role "$2" --scope "$3" -o none
  echo "ok: $2 -> ${1%%_*}"
}
MISSING=0
assign "$STORAGE_APP" "Storage Blob Data Reader"        "$SA_ID/blobServices/default/containers/$CONTAINER"
assign "$QUEUE_APP"   "Storage Queue Data Contributor"  "$SA_ID/queueServices/default/queues/$QUEUE"
[ "$MISSING" = 0 ] || { echo "Re-run this script after the missing consent." >&2; exit 1; }
echo "Role assignments can take a few minutes to take effect; then: SELECT SYSTEM\$VALIDATE_STORAGE_INTEGRATION(...) or LIST @stage."
