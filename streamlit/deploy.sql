-- Deploy the old-demo Streamlit app, 'Group executive cockpit - Finance, Operations, People & Governance' (Streamlit in Snowflake).
-- The app runs as its owner, ROLE_GROUP_EXEC: everyone who opens it sees the group executive's view.
--
-- Step 1, once, as an admin: a schema for apps, and the rights the exec role needs to own an app there.
USE ROLE SYSADMIN;
CREATE SCHEMA IF NOT EXISTS EDW_GOLD.APPS COMMENT = 'Streamlit apps on the Gold layer';
GRANT USAGE ON SCHEMA EDW_GOLD.APPS TO ROLE ROLE_GROUP_EXEC;
GRANT CREATE STAGE, CREATE STREAMLIT ON SCHEMA EDW_GOLD.APPS TO ROLE ROLE_GROUP_EXEC;

-- Step 2: the app, owned by the exec role.
USE ROLE ROLE_GROUP_EXEC;
USE WAREHOUSE WH_BI;
CREATE STAGE IF NOT EXISTS EDW_GOLD.APPS.STG_GROUP_APP COMMENT = 'Files of the ASC Group Performance Streamlit app';
-- Upload the files (a worksheet cannot PUT; use Snowsight's "+ Files" on the stage, or a driver):
--   PUT 'file://<repo>/streamlit/*' @EDW_GOLD.APPS.STG_GROUP_APP AUTO_COMPRESS = FALSE OVERWRITE = TRUE;
CREATE OR REPLACE STREAMLIT EDW_GOLD.APPS.GROUP_PERFORMANCE
  FROM '@EDW_GOLD.APPS.STG_GROUP_APP'
  MAIN_FILE = 'streamlit_app.py'
  QUERY_WAREHOUSE = WH_BI
  RUNTIME_NAME = 'SYSTEM$WAREHOUSE_RUNTIME'   -- packages from environment.yml (Snowflake channel); no internet access needed
  TITLE = 'Group executive cockpit - Finance, Operations, People & Governance'
  COMMENT = 'Same seven pages as the Power BI report ASC_Group_Performance.pbip';
