-- =============================================================================
-- 01b_adls_integration.sql | Let Snowflake read the ADLS Gen2 landing container and hear about new files
-- Run once, as ACCOUNTADMIN, after azure/01_setup_adls.sh. Two account-level integrations:
--   INT_EDW_ADLS      storage integration: Snowflake reads blobs through an Entra app, no keys in any script
--   NINT_EDW_LANDING  notification integration: Snowpipe listens to the storage queue Event Grid writes to
-- Each needs a one-time consent in Entra and one role assignment: run azure/02_grant_snowflake.sh afterwards.
-- =============================================================================
USE ROLE ACCOUNTADMIN;

CREATE STORAGE INTEGRATION IF NOT EXISTS INT_EDW_ADLS
  TYPE = EXTERNAL_STAGE
  STORAGE_PROVIDER = 'AZURE'
  ENABLED = TRUE
  AZURE_TENANT_ID = '<AZURE_TENANT_ID>'
  STORAGE_ALLOWED_LOCATIONS = ('azure://edwdemolanding.blob.core.windows.net/landing/')
  COMMENT = 'Read the ASC demo ADLS Gen2 landing container (edwdemolanding/landing, UAE North)';

CREATE NOTIFICATION INTEGRATION IF NOT EXISTS NINT_EDW_LANDING
  ENABLED = TRUE
  TYPE = QUEUE
  NOTIFICATION_PROVIDER = AZURE_STORAGE_QUEUE
  AZURE_STORAGE_QUEUE_PRIMARY_URI = 'https://edwdemolanding.queue.core.windows.net/snowpipe-events'
  AZURE_TENANT_ID = '<AZURE_TENANT_ID>'
  COMMENT = 'Snowpipe auto-ingest: Event Grid writes BlobCreated events for landing/bronze/ to this queue';

GRANT USAGE ON INTEGRATION INT_EDW_ADLS     TO ROLE ROLE_ELT_ADMIN;
GRANT USAGE ON INTEGRATION NINT_EDW_LANDING TO ROLE ROLE_ELT_ADMIN;

-- The consent link and the app name of each integration (used by azure/02_grant_snowflake.sh):
DESC STORAGE INTEGRATION INT_EDW_ADLS;
DESC NOTIFICATION INTEGRATION NINT_EDW_LANDING;
