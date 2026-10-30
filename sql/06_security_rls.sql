-- =============================================================================
-- 06_security_rls.sql  |  Row access policies (entity / station / airline), dynamic masking
-- (payroll & personal data), persona mapping tables. Applied to Gold STAR + AGG.
-- Personas:  ROLE_GROUP_EXEC  all rows, PII masked, payroll masked
--            ROLE_FIN_ASC     entity ASC only, PII masked, payroll masked
--            ROLE_STATION_MGR own station(s) only, PII masked
--            ROLE_HR_BP       all rows, PII + payroll UNMASKED (HR legitimate use)
--            ROLE_AIRLINE_AM  assigned airline(s) only; employee data hidden
--            ROLE_INTERNAL_AUDIT all rows incl. Bronze/Silver, PII shown as SHA2 hash (traceable, not readable)
-- =============================================================================
USE ROLE ROLE_ELT_ADMIN;
USE WAREHOUSE WH_ELT;
USE SCHEMA EDW_GOLD.SECURITY;

-- ------------------------------------------------------------------ mapping tables
CREATE OR REPLACE TABLE PERSONA_ENTITY_MAP  (role_name VARCHAR(40), user_name VARCHAR(100), entity_key NUMBER(3),  note VARCHAR(200));
CREATE OR REPLACE TABLE PERSONA_STATION_MAP (role_name VARCHAR(40), user_name VARCHAR(100), station_key NUMBER(3), note VARCHAR(200));
CREATE OR REPLACE TABLE PERSONA_AIRLINE_MAP (role_name VARCHAR(40), user_name VARCHAR(100), airline_key NUMBER(4), note VARCHAR(200));
-- user_name = '*' means "every user holding the role"; a specific user_name narrows further (account-manager portfolios)

INSERT INTO PERSONA_ENTITY_MAP VALUES
  ('ROLE_GROUP_EXEC',     '*', 1, 'Group view'), ('ROLE_GROUP_EXEC', '*', 2, NULL), ('ROLE_GROUP_EXEC', '*', 3, NULL), ('ROLE_GROUP_EXEC', '*', 4, NULL),
  ('ROLE_FIN_ASC',        '*', 1, 'ASC B.S.C.(c) finance only'),
  ('ROLE_HR_BP',          '*', 1, NULL), ('ROLE_HR_BP', '*', 2, NULL), ('ROLE_HR_BP', '*', 3, NULL), ('ROLE_HR_BP', '*', 4, NULL),
  ('ROLE_STATION_MGR',    '*', 1, 'BYP station manager sits in ASC'),
  ('ROLE_STATION_MGR',    'DEMO_STATION_MGR_DMM', 4, 'DMM and RUH are ASCSA stations; without this the station map and entity map cancel out'),
  ('ROLE_AIRLINE_AM',     '*', 1, 'Airline AMs see ASC commercial data'),
  ('ROLE_INTERNAL_AUDIT', '*', 1, NULL), ('ROLE_INTERNAL_AUDIT', '*', 2, NULL), ('ROLE_INTERNAL_AUDIT', '*', 3, NULL), ('ROLE_INTERNAL_AUDIT', '*', 4, NULL);

INSERT INTO PERSONA_STATION_MAP VALUES
  ('ROLE_STATION_MGR', '*', 1, 'Default: BYP'),
  ('ROLE_STATION_MGR', 'DEMO_STATION_MGR_DMM', 2, 'Example: a ASCSA station manager mapped to DMM instead'),
  ('ROLE_STATION_MGR', 'DEMO_STATION_MGR_DMM', 3, 'and RUH');

INSERT INTO PERSONA_AIRLINE_MAP VALUES
  ('ROLE_AIRLINE_AM', 'DEMO_AM_MENON',    4, 'R. Menon portfolio: BA'), ('ROLE_AIRLINE_AM', 'DEMO_AM_MENON', 5, 'EK'), ('ROLE_AIRLINE_AM', 'DEMO_AM_MENON', 6, 'FZ'),
  ('ROLE_AIRLINE_AM', 'DEMO_AM_KARIM',  2, 'S. Karim portfolio: QR'), ('ROLE_AIRLINE_AM', 'DEMO_AM_KARIM', 3, 'EY'), ('ROLE_AIRLINE_AM', 'DEMO_AM_KARIM', 8, 'SV'),
  ('ROLE_AIRLINE_AM', 'DEMO_AM_FARIS',  1, 'N. Faris portfolio: GC'), ('ROLE_AIRLINE_AM', 'DEMO_AM_FARIS', 7, 'TK'), ('ROLE_AIRLINE_AM', 'DEMO_AM_FARIS', 9, 'Charter'),
  ('ROLE_AIRLINE_AM', '*',                 9, 'Every AM may see the pooled Charter line');

-- ------------------------------------------------------------------ row access policies
-- One policy per fact shape (a table can carry only one row access policy).
-- A policy still attached to a table cannot be replaced. 02-04 rebuild every table below, but the live
-- board from 10_live_pipeline.sql survives a rerun, so detach it here and re-attach it after the policies.
ALTER TABLE IF EXISTS EDW_GOLD.AGG.LIVE_FLIGHT_BOARD DROP ALL ROW ACCESS POLICIES;
CREATE OR REPLACE ROW ACCESS POLICY RAP_ENTITY_STATION_AIRLINE AS (p_entity_key NUMBER, p_station_key NUMBER, p_airline_key NUMBER) RETURNS BOOLEAN ->
  CURRENT_ROLE() IN ('ROLE_ELT_ADMIN', 'ACCOUNTADMIN', 'SYSADMIN')
  OR (
       EXISTS (SELECT 1 FROM EDW_GOLD.SECURITY.PERSONA_ENTITY_MAP m WHERE m.role_name = CURRENT_ROLE() AND m.user_name IN ('*', CURRENT_USER()) AND m.entity_key = p_entity_key)
   AND (CURRENT_ROLE() <> 'ROLE_STATION_MGR'
        OR EXISTS (SELECT 1 FROM EDW_GOLD.SECURITY.PERSONA_STATION_MAP s WHERE s.role_name = CURRENT_ROLE() AND s.station_key = p_station_key
                   AND s.user_name = IFF(EXISTS (SELECT 1 FROM EDW_GOLD.SECURITY.PERSONA_STATION_MAP u WHERE u.role_name = CURRENT_ROLE() AND u.user_name = CURRENT_USER()), CURRENT_USER(), '*')))
   AND (CURRENT_ROLE() <> 'ROLE_AIRLINE_AM'
        OR EXISTS (SELECT 1 FROM EDW_GOLD.SECURITY.PERSONA_AIRLINE_MAP a WHERE a.role_name = CURRENT_ROLE() AND a.user_name IN ('*', CURRENT_USER()) AND a.airline_key = p_airline_key))
  );

CREATE OR REPLACE ROW ACCESS POLICY RAP_ENTITY_AIRLINE AS (p_entity_key NUMBER, p_airline_key NUMBER) RETURNS BOOLEAN ->
  CURRENT_ROLE() IN ('ROLE_ELT_ADMIN', 'ACCOUNTADMIN', 'SYSADMIN')
  OR (
       EXISTS (SELECT 1 FROM EDW_GOLD.SECURITY.PERSONA_ENTITY_MAP m WHERE m.role_name = CURRENT_ROLE() AND m.user_name IN ('*', CURRENT_USER()) AND m.entity_key = p_entity_key)
   AND (CURRENT_ROLE() <> 'ROLE_AIRLINE_AM'
        OR (p_airline_key IS NOT NULL AND EXISTS (SELECT 1 FROM EDW_GOLD.SECURITY.PERSONA_AIRLINE_MAP a WHERE a.role_name = CURRENT_ROLE() AND a.user_name IN ('*', CURRENT_USER()) AND a.airline_key = p_airline_key)))
  );

CREATE OR REPLACE ROW ACCESS POLICY RAP_ENTITY AS (p_entity_key NUMBER) RETURNS BOOLEAN ->
  CURRENT_ROLE() IN ('ROLE_ELT_ADMIN', 'ACCOUNTADMIN', 'SYSADMIN')
  OR EXISTS (SELECT 1 FROM EDW_GOLD.SECURITY.PERSONA_ENTITY_MAP m WHERE m.role_name = CURRENT_ROLE() AND m.user_name IN ('*', CURRENT_USER()) AND m.entity_key = p_entity_key);

-- Employee rows: airline account managers get nothing; everyone else is scoped by entity
CREATE OR REPLACE ROW ACCESS POLICY RAP_EMPLOYEE AS (p_entity_key NUMBER) RETURNS BOOLEAN ->
  CURRENT_ROLE() IN ('ROLE_ELT_ADMIN', 'ACCOUNTADMIN', 'SYSADMIN')
  OR (CURRENT_ROLE() <> 'ROLE_AIRLINE_AM'
      AND EXISTS (SELECT 1 FROM EDW_GOLD.SECURITY.PERSONA_ENTITY_MAP m WHERE m.role_name = CURRENT_ROLE() AND m.user_name IN ('*', CURRENT_USER()) AND m.entity_key = p_entity_key));

ALTER TABLE EDW_GOLD.STAR.FACT_CATERING_UPLIFT  ADD ROW ACCESS POLICY RAP_ENTITY_STATION_AIRLINE ON (entity_key, station_key, airline_key);
ALTER TABLE EDW_GOLD.STAR.FACT_AIRLINE_ORDER    ADD ROW ACCESS POLICY RAP_ENTITY_STATION_AIRLINE ON (entity_key, station_key, airline_key);
ALTER TABLE EDW_GOLD.AGG.AGG_DAILY_FLIGHTS      ADD ROW ACCESS POLICY RAP_ENTITY_STATION_AIRLINE ON (entity_key, station_key, airline_key);
ALTER TABLE EDW_GOLD.STAR.FACT_FINANCE_POSTING  ADD ROW ACCESS POLICY RAP_ENTITY_AIRLINE ON (entity_key, airline_key);
ALTER TABLE EDW_GOLD.STAR.FACT_WORK_ORDER       ADD ROW ACCESS POLICY RAP_ENTITY ON (entity_key);
ALTER TABLE EDW_GOLD.STAR.FACT_LABOUR_COST      ADD ROW ACCESS POLICY RAP_ENTITY ON (entity_key);
ALTER TABLE EDW_GOLD.STAR.FACT_PURCHASE_ORDER   ADD ROW ACCESS POLICY RAP_ENTITY ON (entity_key);
ALTER TABLE EDW_GOLD.STAR.DIM_COST_CENTER       ADD ROW ACCESS POLICY RAP_ENTITY ON (entity_key);
ALTER TABLE EDW_GOLD.STAR.DIM_EMPLOYEE          ADD ROW ACCESS POLICY RAP_EMPLOYEE ON (entity_key);
-- AGG_MONTHLY_AIRLINE_PNL has no entity column (ASC commercial view): airline scoping only
CREATE OR REPLACE ROW ACCESS POLICY RAP_AIRLINE AS (p_airline_key NUMBER) RETURNS BOOLEAN ->
  CURRENT_ROLE() <> 'ROLE_AIRLINE_AM'
  OR EXISTS (SELECT 1 FROM EDW_GOLD.SECURITY.PERSONA_AIRLINE_MAP a WHERE a.role_name = CURRENT_ROLE() AND a.user_name IN ('*', CURRENT_USER()) AND a.airline_key = p_airline_key);
ALTER TABLE EDW_GOLD.AGG.AGG_MONTHLY_AIRLINE_PNL ADD ROW ACCESS POLICY RAP_AIRLINE ON (airline_key);
ALTER TABLE IF EXISTS EDW_GOLD.AGG.LIVE_FLIGHT_BOARD ADD ROW ACCESS POLICY RAP_ENTITY_STATION_AIRLINE ON (entity_key, station_key, airline_key);

-- ------------------------------------------------------------------ dynamic data masking
-- Payroll amounts: HR BP sees values; audit sees a banded value; everyone else NULL
CREATE OR REPLACE MASKING POLICY MP_PAYROLL_AMOUNT AS (val NUMBER) RETURNS NUMBER ->
  CASE WHEN CURRENT_ROLE() IN ('ROLE_HR_BP', 'ROLE_ELT_ADMIN', 'ACCOUNTADMIN') THEN val
       WHEN CURRENT_ROLE() = 'ROLE_INTERNAL_AUDIT' THEN ROUND(val, -2)          -- banded to nearest 100 USD
       ELSE NULL END;

-- Hourly rate drives labour cost measures, so it stays visible at aggregate level but is rounded for non-HR roles
CREATE OR REPLACE MASKING POLICY MP_HOURLY_RATE AS (val NUMBER) RETURNS NUMBER ->
  CASE WHEN CURRENT_ROLE() IN ('ROLE_HR_BP', 'ROLE_ELT_ADMIN', 'ACCOUNTADMIN', 'ROLE_INTERNAL_AUDIT') THEN val ELSE ROUND(val, 0) END;

-- Names: full for HR, hashed for audit, masked for everyone else
CREATE OR REPLACE MASKING POLICY MP_PERSON_NAME AS (val VARCHAR) RETURNS VARCHAR ->
  CASE WHEN CURRENT_ROLE() IN ('ROLE_HR_BP', 'ROLE_ELT_ADMIN', 'ACCOUNTADMIN') THEN val
       WHEN CURRENT_ROLE() = 'ROLE_INTERNAL_AUDIT' THEN 'H:' || LEFT(SHA2(val, 256), 12)
       ELSE '***MASKED***' END;

-- National ID / passport: never shown except HR; audit gets hash; others get last-3 pattern
CREATE OR REPLACE MASKING POLICY MP_NATIONAL_ID AS (val VARCHAR) RETURNS VARCHAR ->
  CASE WHEN CURRENT_ROLE() IN ('ROLE_HR_BP', 'ROLE_ELT_ADMIN', 'ACCOUNTADMIN') THEN val
       WHEN CURRENT_ROLE() = 'ROLE_INTERNAL_AUDIT' THEN 'H:' || LEFT(SHA2(val, 256), 12)
       ELSE REPEAT('*', GREATEST(LENGTH(val) - 3, 0)) || RIGHT(val, 3) END;   -- Snowflake regex has no look-ahead, so no '.(?=.{3})'

CREATE OR REPLACE MASKING POLICY MP_EMAIL AS (val VARCHAR) RETURNS VARCHAR ->
  CASE WHEN CURRENT_ROLE() IN ('ROLE_HR_BP', 'ROLE_ELT_ADMIN', 'ACCOUNTADMIN') THEN val
       ELSE REGEXP_REPLACE(val, '^[^@]+', '*****') END;

CREATE OR REPLACE MASKING POLICY MP_DOB AS (val DATE) RETURNS DATE ->
  CASE WHEN CURRENT_ROLE() IN ('ROLE_HR_BP', 'ROLE_ELT_ADMIN', 'ACCOUNTADMIN') THEN val
       ELSE DATE_TRUNC('year', val) END;                                        -- year only (age banding still works)

-- Vendor bank details (procurement-sensitive)
CREATE OR REPLACE MASKING POLICY MP_IBAN AS (val VARCHAR) RETURNS VARCHAR ->
  CASE WHEN CURRENT_ROLE() IN ('ROLE_ELT_ADMIN', 'ACCOUNTADMIN', 'ROLE_INTERNAL_AUDIT', 'ROLE_FIN_ASC') THEN val ELSE LEFT(val, 4) || '****' || RIGHT(val, 4) END;

ALTER TABLE EDW_GOLD.STAR.DIM_EMPLOYEE MODIFY COLUMN monthly_salary_usd    SET MASKING POLICY MP_PAYROLL_AMOUNT;
ALTER TABLE EDW_GOLD.STAR.DIM_EMPLOYEE MODIFY COLUMN housing_allowance_usd SET MASKING POLICY MP_PAYROLL_AMOUNT;
ALTER TABLE EDW_GOLD.STAR.DIM_EMPLOYEE MODIFY COLUMN hourly_rate_usd       SET MASKING POLICY MP_HOURLY_RATE;
ALTER TABLE EDW_GOLD.STAR.DIM_EMPLOYEE MODIFY COLUMN full_name             SET MASKING POLICY MP_PERSON_NAME;
ALTER TABLE EDW_GOLD.STAR.DIM_EMPLOYEE MODIFY COLUMN first_name            SET MASKING POLICY MP_PERSON_NAME;
ALTER TABLE EDW_GOLD.STAR.DIM_EMPLOYEE MODIFY COLUMN last_name             SET MASKING POLICY MP_PERSON_NAME;
ALTER TABLE EDW_GOLD.STAR.DIM_EMPLOYEE MODIFY COLUMN national_id           SET MASKING POLICY MP_NATIONAL_ID;
ALTER TABLE EDW_GOLD.STAR.DIM_EMPLOYEE MODIFY COLUMN work_email            SET MASKING POLICY MP_EMAIL;
ALTER TABLE EDW_GOLD.STAR.DIM_EMPLOYEE MODIFY COLUMN date_of_birth         SET MASKING POLICY MP_DOB;
ALTER TABLE EDW_GOLD.STAR.DIM_VENDOR   MODIFY COLUMN iban                  SET MASKING POLICY MP_IBAN;

-- Silver copies of PII get the same policies (audit reads Silver)
ALTER TABLE EDW_SILVER.CONFORMED.SF_EMPLOYEE_CONFORMED MODIFY COLUMN monthly_salary_usd SET MASKING POLICY MP_PAYROLL_AMOUNT;
ALTER TABLE EDW_SILVER.CONFORMED.SF_EMPLOYEE_CONFORMED MODIFY COLUMN national_id        SET MASKING POLICY MP_NATIONAL_ID;
ALTER TABLE EDW_SILVER.CONFORMED.SF_EMPLOYEE_CONFORMED MODIFY COLUMN full_name          SET MASKING POLICY MP_PERSON_NAME;
ALTER TABLE EDW_BRONZE.RAW.SF_EMPLOYEE_MASTER MODIFY COLUMN BASE_SALARY SET MASKING POLICY MP_PAYROLL_AMOUNT;
ALTER TABLE EDW_BRONZE.RAW.SF_EMPLOYEE_MASTER MODIFY COLUMN NATIONAL_ID SET MASKING POLICY MP_NATIONAL_ID;

-- Object tagging for the governance catalog
CREATE TAG IF NOT EXISTS EDW_GOLD.SECURITY.SENSITIVITY ALLOWED_VALUES 'PUBLIC', 'INTERNAL', 'CONFIDENTIAL', 'RESTRICTED-PII', 'RESTRICTED-PAYROLL';
ALTER TABLE EDW_GOLD.STAR.DIM_EMPLOYEE MODIFY COLUMN monthly_salary_usd SET TAG EDW_GOLD.SECURITY.SENSITIVITY = 'RESTRICTED-PAYROLL';
ALTER TABLE EDW_GOLD.STAR.DIM_EMPLOYEE MODIFY COLUMN national_id        SET TAG EDW_GOLD.SECURITY.SENSITIVITY = 'RESTRICTED-PII';
ALTER TABLE EDW_GOLD.STAR.DIM_EMPLOYEE MODIFY COLUMN full_name          SET TAG EDW_GOLD.SECURITY.SENSITIVITY = 'RESTRICTED-PII';
ALTER TABLE EDW_GOLD.STAR.FACT_FINANCE_POSTING SET TAG EDW_GOLD.SECURITY.SENSITIVITY = 'CONFIDENTIAL';
ALTER TABLE EDW_GOLD.STAR.FACT_CATERING_UPLIFT SET TAG EDW_GOLD.SECURITY.SENSITIVITY = 'INTERNAL';

-- ------------------------------------------------------------------ live persona test (run each block while the audience watches the row counts change)
-- USE ROLE ROLE_GROUP_EXEC;    SELECT e.entity_code, COUNT(*) FROM EDW_GOLD.STAR.FACT_FINANCE_POSTING f JOIN EDW_GOLD.STAR.DIM_ENTITY e USING (entity_key) GROUP BY 1;   -- 4 entities
-- USE ROLE ROLE_FIN_ASC;       SELECT e.entity_code, COUNT(*) FROM EDW_GOLD.STAR.FACT_FINANCE_POSTING f JOIN EDW_GOLD.STAR.DIM_ENTITY e USING (entity_key) GROUP BY 1;   -- ASC only
-- USE ROLE ROLE_STATION_MGR;   SELECT s.station_code, COUNT(*) FROM EDW_GOLD.STAR.FACT_CATERING_UPLIFT f JOIN EDW_GOLD.STAR.DIM_STATION s USING (station_key) GROUP BY 1; -- BYP only
-- USE ROLE ROLE_AIRLINE_AM;    SELECT a.airline_name, COUNT(*) FROM EDW_GOLD.STAR.FACT_CATERING_UPLIFT f JOIN EDW_GOLD.STAR.DIM_AIRLINE a USING (airline_key) GROUP BY 1; -- portfolio only
-- USE ROLE ROLE_HR_BP;         SELECT employee_id, full_name, monthly_salary_usd FROM EDW_GOLD.STAR.DIM_EMPLOYEE LIMIT 5;      -- clear
-- USE ROLE ROLE_GROUP_EXEC;    SELECT employee_id, full_name, monthly_salary_usd FROM EDW_GOLD.STAR.DIM_EMPLOYEE LIMIT 5;      -- ***MASKED*** / NULL
-- USE ROLE ROLE_INTERNAL_AUDIT;SELECT employee_id, full_name, national_id, monthly_salary_usd FROM EDW_GOLD.STAR.DIM_EMPLOYEE LIMIT 5; -- H:hash / banded

-- Governance proof: who accessed payroll columns (Enterprise edition ACCESS_HISTORY)
-- SELECT query_start_time, user_name, direct_objects_accessed FROM SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY
-- WHERE ARRAY_TO_STRING(direct_objects_accessed, ',') ILIKE '%DIM_EMPLOYEE%' ORDER BY 1 DESC LIMIT 20;
