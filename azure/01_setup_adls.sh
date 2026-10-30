#!/usr/bin/env bash
# Landing zone for the ASC demo: an ADLS Gen2 container Snowflake reads from, plus the Event Grid -> storage queue
# path that tells Snowpipe when a file arrives. Safe to re-run (every step is create-if-missing). No secrets are
# written anywhere: the storage key is read at run time and only held in this shell.
#   bash azure/01_setup_adls.sh
# Needs: az CLI signed in to the subscription that should own the resources (az login; az account set -s <id>).
set -euo pipefail
export MSYS_NO_PATHCONV=1   # Git Bash on Windows would otherwise rewrite "/subscriptions/..." into a C:/ path
RG="${RG:-rg-edw-demo}"
LOC="${LOC:-uaenorth}"            # same region as the Snowflake account (AZURE_UAENORTH): data stays in the UAE
SA="${SA:-edwdemolanding}"
CONTAINER="${CONTAINER:-landing}"
QUEUE="${QUEUE:-snowpipe-events}"
TOPIC="${TOPIC:-evgt-asc-landing}"

echo "Subscription: $(az account show --query name -o tsv)"
echo "1/6 Event Grid provider"; az provider register -n Microsoft.EventGrid --wait
echo "2/6 Resource group $RG ($LOC)"; az group create -n "$RG" -l "$LOC" -o none
echo "3/6 Storage account $SA (ADLS Gen2: hierarchical namespace on)"
az storage account create -n "$SA" -g "$RG" -l "$LOC" --sku Standard_LRS --kind StorageV2 --hns true \
  --min-tls-version TLS1_2 --allow-blob-public-access false --https-only true -o none
SA_ID="$(az storage account show -n "$SA" -g "$RG" --query id -o tsv)"
export AZURE_STORAGE_ACCOUNT="$SA" AZURE_STORAGE_KEY="$(az storage account keys list -g "$RG" -n "$SA" --query '[0].value' -o tsv)"
echo "4/6 Container $CONTAINER and queue $QUEUE"
az storage container create -n "$CONTAINER" --auth-mode key -o none
az storage queue create -n "$QUEUE" --auth-mode key -o none
echo "5/6 Event Grid system topic on the storage account"
az eventgrid system-topic create -n "$TOPIC" -g "$RG" -l "$LOC" --source "$SA_ID" --topic-type microsoft.storage.storageaccounts -o none
echo "6/6 Event subscription: new files under $CONTAINER/bronze/ -> queue"
az eventgrid system-topic event-subscription create -n evgs-snowpipe --system-topic-name "$TOPIC" -g "$RG" \
  --endpoint-type storagequeue --endpoint "$SA_ID/queueservices/default/queues/$QUEUE" \
  --included-event-types Microsoft.Storage.BlobCreated \
  --subject-begins-with "/blobServices/default/containers/$CONTAINER/blobs/bronze/" -o none
echo "Done. Blob URL for Snowflake: azure://$SA.blob.core.windows.net/$CONTAINER/   Queue URI: https://$SA.queue.core.windows.net/$QUEUE"
