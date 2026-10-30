-- =============================================================================
-- 01c_adls_stages.sql | Point the landing stages at the ADLS Gen2 container instead of Snowflake-internal storage
-- Replaces STG_SOURCE_DROP and STG_GOLD_SEED with external stages of the SAME names, so every COPY INTO in
-- 02, 03, 04 and 09 works unchanged (they only name the stage and a path). STG_QUARANTINE stays internal:
-- Snowflake writes quarantined files into it. Needs INT_EDW_ADLS (01b_adls_integration.sql) and the Azure roles
-- (azure/02_grant_snowflake.sh). Run as ROLE_ELT_ADMIN after 01_snowflake_setup.sql. Files: azure/03_upload.sh.
-- =============================================================================
USE ROLE ROLE_ELT_ADMIN;
USE WAREHOUSE WH_ELT;

CREATE OR REPLACE STAGE EDW_BRONZE.LANDING.STG_SOURCE_DROP
  URL = 'azure://edwdemolanding.blob.core.windows.net/landing/'
  STORAGE_INTEGRATION = INT_EDW_ADLS
  FILE_FORMAT = EDW_BRONZE.LANDING.FF_CSV_STD DIRECTORY = (ENABLE = TRUE)
  COMMENT = 'ADLS Gen2 landing zone (UAE North). Source extracts: bronze/<object>.csv and bad_files/<file>.csv';

CREATE OR REPLACE STAGE EDW_GOLD.STAR.STG_GOLD_SEED
  URL = 'azure://edwdemolanding.blob.core.windows.net/landing/gold_seed/'
  STORAGE_INTEGRATION = INT_EDW_ADLS
  FILE_FORMAT = EDW_BRONZE.LANDING.FF_CSV_HEADER_MATCH DIRECTORY = (ENABLE = TRUE)
  COMMENT = 'Gold CSV seeds in ADLS for the fast-path load (09_gold_seed_fast_path.sql)';
