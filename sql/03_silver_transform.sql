-- =============================================================================
-- 03_silver_transform.sql  |  Silver: cleanse, de-duplicate, conform, MDM, DQ
--   1. Reference data & code harmonisation (entity / airline / station maps)
--   2. Conformed source tables (dedup via QUALIFY, trims/upper-casing, currency to USD)
--   3. MDM: vendor golden records + cross-reference (17 duplicates -> 80 golden)
--   4. DQ: rule registry, row-level quarantine, rule results
-- =============================================================================
USE ROLE ROLE_ELT_ADMIN;
USE WAREHOUSE WH_ELT;
USE SCHEMA EDW_SILVER.CONFORMED;

-- ------------------------------------------------------------------ 1. harmonisation maps
CREATE OR REPLACE TABLE ENTITY_CODE_MAP (
  src_system VARCHAR(20), src_code VARCHAR(80), entity_code VARCHAR(10), entity_key NUMBER(3)
) COMMENT = 'Every source spells the legal entity differently; this is the single harmonisation point';
INSERT INTO ENTITY_CODE_MAP VALUES
  ('SAP',    '1000',                              'ASC',   1), ('SAP',    '1100',             'ASCD',  2),
  ('SAP',    '1200',                              'ASCWF',  3), ('SAP',    '2000',             'ASCSA', 4),
  ('SF',     'Airport Services Co PJSC',          'ASC',   1), ('SF',     'ASC Dev LLC',      'ASCD',  2),
  ('SF',     'ASC Workforce',                     'ASCWF',  3), ('SF',     'ASC Saudi Arabia', 'ASCSA', 4),
  ('MAXIMO', 'BYP-GSE',                           'ASC',   1), ('MAXIMO', 'DMM-GSE',          'ASCSA', 4), ('MAXIMO', 'RUH-GSE', 'ASCSA', 4),
  ('CMS',    'BYP-MAIN',                          'ASC',   1), ('CMS',    'DMM-UNIT',         'ASCSA', 4),
  ('CMS',    'BYP',                               'ASC',   1), ('CMS',    'DMM',              'ASCSA', 4), ('CMS', 'RUH', 'ASCSA', 4),
  ('CONTRACTOR', 'V100212',                       'ASCWF',  3), ('CONTRACTOR', 'V100377',      'ASCWF',  3), ('CONTRACTOR', 'V100451', 'ASCWF', 3);

CREATE OR REPLACE TABLE STATION_CODE_MAP (src_code VARCHAR(20), station_code VARCHAR(3), station_key NUMBER(3));
INSERT INTO STATION_CODE_MAP VALUES ('BYP', 'BYP', 1), ('BYP-MAIN', 'BYP', 1), ('BYP-GSE', 'BYP', 1), ('DMM', 'DMM', 2), ('DMM-UNIT', 'DMM', 2), ('DMM-GSE', 'DMM', 2), ('RUH', 'RUH', 3), ('RUH-GSE', 'RUH', 3);

-- Reference masters are maintained in Silver (in production fed by the MDM hub / SAP master data;
-- in the demo seeded from the pack's reference CSVs, uploaded with:
--   PUT file://<pack>/data/gold/DIM_*.csv @EDW_GOLD.STAR.STG_GOLD_SEED/ AUTO_COMPRESS=FALSE; )
CREATE OR REPLACE TABLE REF_ENTITY (
  entity_key NUMBER(3), entity_code VARCHAR(10), entity_name VARCHAR(80), legal_name VARCHAR(120), country_code VARCHAR(2), local_currency VARCHAR(3),
  sap_company_code VARCHAR(4), sf_legal_entity_name VARCHAR(80), home_station VARCHAR(3)
);
CREATE OR REPLACE TABLE REF_AIRLINE (
  airline_key NUMBER(4), airline_code VARCHAR(3), icao_code VARCHAR(3), airline_name VARCHAR(80), alliance VARCHAR(20), demo_alias VARCHAR(20), contract_type VARCHAR(40),
  contract_margin_pct NUMBER(5,3), base_load_factor NUMBER(5,3), catering_customer BOOLEAN, handling_customer BOOLEAN, country_code VARCHAR(2), account_manager VARCHAR(40),
  contract_id VARCHAR(20), contract_start DATE, contract_end DATE
);
CREATE OR REPLACE TABLE REF_STATION (
  station_key NUMBER(3), station_code VARCHAR(3), icao_code VARCHAR(4), station_name VARCHAR(80), city VARCHAR(40), country_code VARCHAR(2), operating_entity_code VARCHAR(10), timezone VARCHAR(30)
);
CREATE OR REPLACE TABLE REF_COST_CENTER (
  cost_center_key NUMBER(4), cost_center_code VARCHAR(10), cost_center_name VARCHAR(80), entity_code VARCHAR(10), business_unit VARCHAR(40), station_code VARCHAR(3),
  target_headcount NUMBER(5), entity_key NUMBER(3), station_key NUMBER(3), cc_owner VARCHAR(40), is_operational BOOLEAN
);
CREATE OR REPLACE TABLE REF_GL_ACCOUNT (
  gl_account_key NUMBER(4), gl_account VARCHAR(10), gl_description VARCHAR(80), account_class VARCHAR(20), kpi_group VARCHAR(30), is_ebitda BOOLEAN, is_intercompany BOOLEAN,
  natural_sign NUMBER(2), statement_line VARCHAR(30)
);
CREATE OR REPLACE TABLE REF_FLIGHT (
  flight_key NUMBER(5), airline_code VARCHAR(3), flight_number VARCHAR(10), origin VARCHAR(3), destination VARCHAR(3), route_group VARCHAR(20), aircraft_type VARCHAR(6), days_of_week VARCHAR(7),
  station_code VARCHAR(3), service_entity_code VARCHAR(10), catered_by_asc BOOLEAN, handled_by_asc BOOLEAN, sched_dep_local VARCHAR(5), is_night_departure BOOLEAN,
  seats_f NUMBER(4), seats_j NUMBER(4), seats_y NUMBER(4), body_type VARCHAR(10), turnaround_fee_usd NUMBER(10,2), airline_key NUMBER(4), station_key NUMBER(3), entity_key NUMBER(3)
);
CREATE OR REPLACE TABLE REF_MEAL_SPEC (
  meal_key NUMBER(4), menu_spec_code VARCHAR(12), airline_code VARCHAR(3), meal_class VARCHAR(1), meal_class_name VARCHAR(20), meal_type VARCHAR(40), spec_version NUMBER(2),
  effective_from DATE, effective_to DATE, std_food_cost_usd NUMBER(8,3), std_labour_cost_usd NUMBER(8,3), std_overhead_cost_usd NUMBER(8,3), spec_change_reason VARCHAR(120)
);
COPY INTO REF_ENTITY      FROM @EDW_GOLD.STAR.STG_GOLD_SEED/DIM_ENTITY.csv      FILE_FORMAT = (FORMAT_NAME = 'EDW_BRONZE.LANDING.FF_CSV_HEADER_MATCH') MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE;
COPY INTO REF_AIRLINE     FROM @EDW_GOLD.STAR.STG_GOLD_SEED/DIM_AIRLINE.csv     FILE_FORMAT = (FORMAT_NAME = 'EDW_BRONZE.LANDING.FF_CSV_HEADER_MATCH') MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE;
COPY INTO REF_STATION     FROM @EDW_GOLD.STAR.STG_GOLD_SEED/DIM_STATION.csv     FILE_FORMAT = (FORMAT_NAME = 'EDW_BRONZE.LANDING.FF_CSV_HEADER_MATCH') MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE;
COPY INTO REF_COST_CENTER FROM @EDW_GOLD.STAR.STG_GOLD_SEED/DIM_COST_CENTER.csv FILE_FORMAT = (FORMAT_NAME = 'EDW_BRONZE.LANDING.FF_CSV_HEADER_MATCH') MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE;
COPY INTO REF_GL_ACCOUNT  FROM @EDW_GOLD.STAR.STG_GOLD_SEED/DIM_GL_ACCOUNT.csv  FILE_FORMAT = (FORMAT_NAME = 'EDW_BRONZE.LANDING.FF_CSV_HEADER_MATCH') MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE;
COPY INTO REF_FLIGHT      FROM @EDW_GOLD.STAR.STG_GOLD_SEED/DIM_FLIGHT.csv      FILE_FORMAT = (FORMAT_NAME = 'EDW_BRONZE.LANDING.FF_CSV_HEADER_MATCH') MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE;
-- Menu specifications come from the CMS (Bronze), not a seed
INSERT INTO REF_MEAL_SPEC
SELECT ROW_NUMBER() OVER (ORDER BY CARRIER, CLASS, VERSION), MENU_SPEC, CARRIER, CLASS,
       CASE CLASS WHEN 'F' THEN 'First' WHEN 'J' THEN 'Business' ELSE 'Economy' END,
       CASE CLASS WHEN 'F' THEN 'Hot multi-course' WHEN 'J' THEN 'Hot tray service' ELSE 'Hot tray / snack box' END,
       VERSION, VALID_FROM, VALID_TO, STD_FOOD_COST, STD_LABOUR_COST, STD_OVERHEAD_COST, CHANGE_REASON
FROM EDW_BRONZE.RAW.CMS_MENU_COST
QUALIFY ROW_NUMBER() OVER (PARTITION BY MENU_SPEC ORDER BY extracted_at DESC) = 1;

-- ------------------------------------------------------------------ 2. conformed sources
-- 2a. SAP GL actuals + budget: group currency USD, entity harmonised, profit centre -> airline
CREATE OR REPLACE TABLE SAP_GL_CONFORMED AS
SELECT a.GJAHR || '-' || LPAD(a.MONAT, 2, '0')              AS fiscal_period,
       LAST_DAY(a.BUDAT)                                     AS period_end_date,
       m.entity_code, m.entity_key,
       a.KOSTL                                                AS cost_center_code,
       a.HKONT                                                AS gl_account,
       IFF(a.PRCTR = 'PC_GEN', NULL, REPLACE(a.PRCTR, 'PC_', '')) AS airline_code,
       a.DMBTR                                                AS amount_usd,          -- group currency; WRBTR/WAERS kept for audit
       a.WRBTR AS amount_doc_currency, a.WAERS AS doc_currency,
       b.PLAN_AMOUNT_USD                                      AS budget_usd,
       a.POSTING_COUNT, a.batch_id AS src_batch_id, a.row_hash
FROM EDW_BRONZE.RAW.SAP_GL_ACTUALS_MONTHLY a
JOIN ENTITY_CODE_MAP m ON m.src_system = 'SAP' AND m.src_code = a.BUKRS
LEFT JOIN EDW_BRONZE.RAW.SAP_CO_BUDGET_MONTHLY b
  ON b.BUKRS = a.BUKRS AND b.GJAHR = a.GJAHR AND b.MONAT = a.MONAT AND b.KOSTL = a.KOSTL AND b.HKONT = a.HKONT AND b.PRCTR = a.PRCTR
QUALIFY ROW_NUMBER() OVER (PARTITION BY a.BUKRS, a.GJAHR, a.MONAT, a.KOSTL, a.HKONT, a.PRCTR ORDER BY a.extracted_at DESC) = 1;

-- 2b. CMS uplift: live flight-level feed is cleansed, de-duplicated and rolled to the daily conformed grain;
--     the daily history backfill is unioned in. One table, one grain, full period.
CREATE OR REPLACE TABLE CMS_UPLIFT_LIVE_CLEAN AS
SELECT UPLIFT_ID, FLT_DATE,
       UPPER(TRIM(CARRIER))  AS carrier,
       UPPER(TRIM(FLT_NO))   AS flight_number,
       TRIM(DEP_STN)         AS dep_station,
       TRIM(DEST)            AS destination,
       AC_TYPE, CLASS, MENU_SPEC, MEALS_PLANNED, MEALS_UPLIFTED, MEALS_DOWNLIFTED, MEALS_WASTED,
       IFF(DOWNLIFT_LATE_FLAG = 'Y', 1, 0)    AS downlift_late,
       IFF(DELIVERY_ON_TIME_FLAG = 'Y', 1, 0) AS delivery_on_time,
       FOOD_COST, LABOUR_COST, OVERHEAD_COST, BILL_AMOUNT, KITCHEN, batch_id AS src_batch_id, row_hash
FROM EDW_BRONZE.RAW.CMS_UPLIFT_FLIGHT_CLASS
QUALIFY ROW_NUMBER() OVER (PARTITION BY UPLIFT_ID ORDER BY extracted_at DESC) = 1;   -- removes the 26 exact duplicates

CREATE OR REPLACE TABLE CMS_UPLIFT_DAILY AS
WITH live AS (
  SELECT l.FLT_DATE AS uplift_date, l.carrier, f.route_group, l.CLASS AS meal_class, l.MENU_SPEC AS menu_spec_code, l.dep_station AS dep_stn,
         COUNT(*) AS flights, SUM(MEALS_PLANNED) AS meals_planned, SUM(MEALS_UPLIFTED) AS meals_uplifted, SUM(MEALS_DOWNLIFTED) AS meals_downlifted,
         SUM(MEALS_WASTED) AS meals_wasted, SUM(downlift_late) AS downlift_late_cnt, SUM(delivery_on_time) AS deliveries_on_time,
         SUM(FOOD_COST) AS food_cost, SUM(LABOUR_COST) AS labour_cost, SUM(OVERHEAD_COST) AS overhead_cost, SUM(BILL_AMOUNT) AS bill_amount,
         MAX(src_batch_id) AS src_batch_id
  FROM CMS_UPLIFT_LIVE_CLEAN l
  LEFT JOIN REF_FLIGHT f ON f.flight_number = l.flight_number AND f.station_code = l.dep_station
  GROUP BY 1, 2, 3, 4, 5, 6
), hist AS (
  SELECT UPLIFT_DATE AS uplift_date, UPPER(TRIM(CARRIER)) AS carrier, ROUTE_GROUP AS route_group, CLASS AS meal_class, MENU_SPEC AS menu_spec_code, DEP_STN AS dep_stn,
         FLIGHTS AS flights, MEALS_PLANNED AS meals_planned, MEALS_UPLIFTED AS meals_uplifted, MEALS_DOWNLIFTED AS meals_downlifted, MEALS_WASTED AS meals_wasted,
         DOWNLIFT_LATE_CNT AS downlift_late_cnt, DELIVERIES_ON_TIME AS deliveries_on_time, FOOD_COST AS food_cost, LABOUR_COST AS labour_cost, OVERHEAD_COST AS overhead_cost,
         BILL_AMOUNT AS bill_amount, batch_id AS src_batch_id
  FROM EDW_BRONZE.RAW.CMS_UPLIFT_DAILY_HISTORY
  QUALIFY ROW_NUMBER() OVER (PARTITION BY UPLIFT_DATE, CARRIER, ROUTE_GROUP, CLASS, MENU_SPEC, DEP_STN ORDER BY extracted_at DESC) = 1
)
SELECT u.*, m.entity_code, m.entity_key, s.station_key
FROM (SELECT * FROM hist UNION ALL SELECT * FROM live) u
JOIN ENTITY_CODE_MAP m ON m.src_system = 'CMS' AND m.src_code = u.dep_stn
JOIN STATION_CODE_MAP s ON s.src_code = u.dep_stn;

-- 2c. SuccessFactors employees: dedup, entity harmonised, SAR payroll converted to USD
CREATE OR REPLACE TABLE SF_EMPLOYEE_CONFORMED AS
SELECT e.PERSON_ID_EXTERNAL AS employee_id, e.FIRST_NAME, e.LAST_NAME, e.FIRST_NAME || ' ' || e.LAST_NAME AS full_name, e.GENDER, e.NATIONALITY, e.NATIONAL_ID, e.DATE_OF_BIRTH,
       e.EMAIL AS work_email, m.entity_code, m.entity_key, REPLACE(e.COST_CENTER, 'CC-', '') AS cost_center_code, e.DEPARTMENT, e.JOB_TITLE, e.PAY_GRADE AS grade,
       'Permanent' AS employment_type, e.SHIFT_PATTERN, e.HIRE_DATE, e.TERMINATION_DATE, IFF(e.EMP_STATUS = 'A', 'Active', 'Terminated') AS employment_status,
       ROUND(IFF(e.PAY_CURRENCY = 'SAR', e.BASE_SALARY / 3.75, e.BASE_SALARY), 2)         AS monthly_salary_usd,
       ROUND(IFF(e.PAY_CURRENCY = 'SAR', e.HOUSING_ALLOWANCE / 3.75, e.HOUSING_ALLOWANCE), 2) AS housing_allowance_usd,
       e.MANAGER_ID AS manager_employee_id, e.batch_id AS src_batch_id, e.row_hash
FROM EDW_BRONZE.RAW.SF_EMPLOYEE_MASTER e
JOIN ENTITY_CODE_MAP m ON m.src_system = 'SF' AND m.src_code = e.LEGAL_ENTITY
QUALIFY ROW_NUMBER() OVER (PARTITION BY e.PERSON_ID_EXTERNAL ORDER BY e.extracted_at DESC, e.row_hash) = 1;   -- removes 8 duplicate person rows

CREATE OR REPLACE TABLE SF_TIME_CONFORMED AS
SELECT PERSON_ID_EXTERNAL AS employee_id, PERIOD AS fiscal_period, TIME_TYPE_REGULAR_HRS AS regular_hours, TIME_TYPE_OT_HRS AS overtime_hours,
       TIME_TYPE_NIGHT_HRS AS night_hours, TIME_TYPE_LEAVE_HRS AS leave_hours, OT_MULTIPLIER AS ot_multiplier, batch_id AS src_batch_id
FROM EDW_BRONZE.RAW.SF_TIME_ENTRIES_MONTHLY
WHERE APPROVAL_STATUS = 'APPROVED'
QUALIFY ROW_NUMBER() OVER (PARTITION BY PERSON_ID_EXTERNAL, PERIOD ORDER BY extracted_at DESC) = 1;

-- 2d. Contractor feed: history + accepted daily drops (quarantined rows excluded by DQ in step 4)
CREATE OR REPLACE TABLE CONTRACTOR_LINES_CONFORMED AS
SELECT INVOICE_NO, INVOICE_DATE, VENDOR_ID, CONTRACTOR_ID, CONTRACTOR_NAME, POOL_CC AS cost_center_code, DEPLOYED_CC AS deployed_cost_center_code, PERIOD AS fiscal_period,
       REG_HOURS AS regular_hours, OT_HOURS AS overtime_hours, RATE_USD AS hourly_rate_usd, OT_RATE_USD AS ot_rate_usd, AMOUNT_USD AS amount_usd,
       'ASCWF' AS entity_code, 3 AS entity_key, batch_id AS src_batch_id, row_hash
FROM (
  SELECT INVOICE_NO, INVOICE_DATE, VENDOR_ID, CONTRACTOR_ID, CONTRACTOR_NAME, POOL_CC, DEPLOYED_CC, PERIOD, REG_HOURS, OT_HOURS, RATE_USD, OT_RATE_USD, AMOUNT_USD, batch_id, row_hash, extracted_at
  FROM EDW_BRONZE.RAW.CONTRACTOR_FEED_INVOICE_LINES
  UNION ALL
  SELECT INVOICE_NO, INVOICE_DATE, VENDOR_ID, CONTRACTOR_ID, CONTRACTOR_NAME, POOL_CC, DEPLOYED_CC, PERIOD, REG_HOURS, OT_HOURS, RATE_USD, OT_RATE_USD, AMOUNT_USD, batch_id, row_hash, extracted_at
  FROM EDW_BRONZE.RAW.CONTRACTOR_FEED_DAILY
)
QUALIFY ROW_NUMBER() OVER (PARTITION BY INVOICE_NO ORDER BY extracted_at DESC) = 1;

-- 2e. Maximo: assets snapshot & work orders with harmonised entity/station
CREATE OR REPLACE TABLE MAXIMO_ASSET_SNAPSHOT AS
SELECT a.ASSETNUM AS asset_id, a.DESCRIPTION, a.ASSETTYPE AS asset_class, a.MANUFACTURER AS make, a.MODEL, YEAR(a.INSTALLDATE) AS year_of_manufacture, a.PURCHASEPRICE AS acquisition_cost_usd,
       REPLACE(a.GLACCOUNT, 'CC-', '') AS cost_center_code, s.station_code, s.station_key, m.entity_code, m.entity_key,
       INITCAP(a.STATUS) AS status, IFF(a.PRIORITY = 1, 'High', 'Medium') AS criticality, a.CHANGEDATE AS source_change_date, a.batch_id AS src_batch_id
FROM EDW_BRONZE.RAW.MAXIMO_ASSETS a
JOIN ENTITY_CODE_MAP m ON m.src_system = 'MAXIMO' AND m.src_code = a.SITEID
JOIN STATION_CODE_MAP s ON s.src_code = a.SITEID
QUALIFY ROW_NUMBER() OVER (PARTITION BY a.ASSETNUM ORDER BY a.extracted_at DESC) = 1;

CREATE OR REPLACE TABLE MAXIMO_WO_CONFORMED AS
SELECT w.WONUM AS wo_id, w.ASSETNUM AS asset_id, w.WORKTYPE AS wo_type, w.FAILURECODE AS fault_code, w.PROBLEMCODE AS fault_description, w.WOPRIORITY AS priority,
       w.REPORTDATE AS reported_ts, w.ACTSTART AS start_ts, w.ACTFINISH AS finish_ts, DATE(w.REPORTDATE) AS wo_date,
       w.DOWNTIME_HRS AS downtime_hours, ROUND(DATEDIFF(minute, w.ACTSTART, w.ACTFINISH) / 60.0, 2) AS repair_hours, w.ACTLABHRS AS labour_hours,
       w.ACTMATCOST AS parts_cost_usd, w.ACTLABCOST AS labour_cost_usd, w.STATUS, w.LEAD AS technician_id,
       REPLACE(w.GLACCOUNT, 'CC-', '') AS cost_center_code, s.station_code, s.station_key, m.entity_code, m.entity_key, w.batch_id AS src_batch_id, w.row_hash
FROM EDW_BRONZE.RAW.MAXIMO_WORK_ORDERS w
JOIN ENTITY_CODE_MAP m ON m.src_system = 'MAXIMO' AND m.src_code = w.SITEID
JOIN STATION_CODE_MAP s ON s.src_code = w.SITEID
QUALIFY ROW_NUMBER() OVER (PARTITION BY w.WONUM ORDER BY w.extracted_at DESC) = 1;

-- 2f. Portal orders & SITA movements
CREATE OR REPLACE TABLE PORTAL_ORDERS_CONFORMED AS
SELECT ORDER_DATE AS order_date, UPPER(TRIM(AIRLINE)) AS airline_code, STATION AS station_code, ORDERS_SUBMITTED, ORDERS_AMENDED_AFTER_CUTOFF, SPML_ORDERS, SPML_UNFULFILLED,
       SLA_EVENTS, SLA_BREACHES, AVG_LEAD_HOURS, batch_id AS src_batch_id
FROM EDW_BRONZE.RAW.PORTAL_ORDERS_DAILY
QUALIFY ROW_NUMBER() OVER (PARTITION BY ORDER_DATE, AIRLINE, STATION ORDER BY extracted_at DESC) = 1;

CREATE OR REPLACE TABLE SITA_MOVEMENTS AS
SELECT MSG_ID, MSG_TYPE, FLT_NO AS flight_number, FLT_DATE AS flight_date, AC_REG, ORIGIN, DEST, STATION AS station_code,
       TRY_TO_TIMESTAMP_NTZ(STD, 'YYYY-MM-DD HH24:MI') AS std_ts, TRY_TO_TIMESTAMP_NTZ(ATD, 'YYYY-MM-DD HH24:MI') AS atd_ts,
       DELAY_MIN, DELAY_CODE, IFF(DELAY_MIN <= 15, 1, 0) AS on_time_flag, batch_id AS src_batch_id
FROM EDW_BRONZE.RAW.SITA_MESSAGES
QUALIFY ROW_NUMBER() OVER (PARTITION BY MSG_ID ORDER BY extracted_at DESC) = 1;

-- ------------------------------------------------------------------ 3. MDM - vendor golden records
USE SCHEMA EDW_SILVER.MDM;

-- Normalised match key: upper-case, strip legal-form tokens and punctuation
CREATE OR REPLACE FUNCTION NORMALISE_VENDOR_NAME(n VARCHAR)
RETURNS VARCHAR
AS
$$
  REGEXP_REPLACE(
    REGEXP_REPLACE(UPPER(REPLACE(n, '&', 'AND')),
      '\\b(W\\.?L\\.?L\\.?|P\\.?J\\.?S\\.?C\\.?|\\(?C\\)?|CLOSED|S\\.?P\\.?C\\.?|CO\\.?|COMPANY|EST\\.?|L\\.?L\\.?C\\.?|LIMITED|LTD)\\b', ''),
    '[^A-Z0-9]', '')
$$;

CREATE OR REPLACE TABLE VENDOR_SOURCE_RECORDS AS
SELECT LIFNR AS source_vendor_id, 'SAP' AS src_system, NAME1 AS vendor_name, NORMALISE_VENDOR_NAME(NAME1) AS name_key, STCD1 AS cr_number, IBAN AS iban, LAND1 AS country,
       ZTERM AS payment_terms, CATEGORY AS category, ERNAM AS created_by, ERDAT AS created_on, extracted_at
FROM EDW_BRONZE.RAW.SAP_VENDOR_MASTER WHERE COALESCE(LOEVM, '') <> 'X'
UNION ALL
SELECT ERP_VENDOR_ID, 'ARIBA', SUPPLIER_NAME, NORMALISE_VENDOR_NAME(SUPPLIER_NAME), TAX_ID, BANK_ACCOUNT, COUNTRY, NULL, COMMODITY, 'ARIBA_SYNC', NULL, extracted_at
FROM EDW_BRONZE.RAW.ARIBA_SUPPLIERS;

-- Match groups: records sharing CR number OR IBAN OR normalised name belong to one golden record.
CREATE OR REPLACE TABLE VENDOR_MATCH_GROUPS AS
WITH sap AS (SELECT * FROM VENDOR_SOURCE_RECORDS WHERE src_system = 'SAP'),
pairs AS (
  SELECT a.source_vendor_id AS id_a, b.source_vendor_id AS id_b,
         CASE WHEN a.cr_number = b.cr_number AND a.iban = b.iban THEN 'CR_NUMBER+IBAN exact'
              WHEN a.cr_number = b.cr_number THEN 'CR_NUMBER exact'
              WHEN a.iban = b.iban THEN 'IBAN exact'
              ELSE 'Normalised name' END AS match_rule,
         CASE WHEN a.cr_number = b.cr_number AND a.iban = b.iban THEN 0.99 WHEN a.cr_number = b.cr_number OR a.iban = b.iban THEN 0.95 ELSE 0.85 END AS confidence
  FROM sap a JOIN sap b ON a.source_vendor_id <> b.source_vendor_id
   AND (a.cr_number = b.cr_number OR a.iban = b.iban
        -- A name match alone is trusted only when the identifiers do not contradict it: two records
        -- with different CR numbers AND different IBANs are different companies, even if their names
        -- normalise to the same key (e.g. "Horizon Facilities Management P.J.S.C." vs "... Co. L.L.C.").
        OR (a.name_key = b.name_key
            AND NOT (COALESCE(a.cr_number <> b.cr_number, FALSE) AND COALESCE(a.iban <> b.iban, FALSE))))
)
SELECT s.source_vendor_id,
       COALESCE(MIN(LEAST(p.id_a, p.id_b)), s.source_vendor_id) AS group_id,      -- lowest vendor id in the group = group key
       MAX_BY(p.match_rule, p.confidence) AS match_rule, MAX(p.confidence) AS confidence   -- label of the strongest match
FROM sap s LEFT JOIN pairs p ON p.id_a = s.source_vendor_id
GROUP BY s.source_vendor_id;

-- Survivorship: prefer the SAP_MIGRATION record (system of record), then the oldest id.
CREATE OR REPLACE TABLE VENDOR_GOLDEN AS
SELECT g.group_id AS golden_vendor_id,
       r.vendor_name AS golden_vendor_name, r.category, r.cr_number, r.iban, r.country, r.payment_terms, r.created_by, r.created_on,
       COUNT(*) OVER (PARTITION BY g.group_id) AS source_record_count,
       CURRENT_TIMESTAMP() AS mastered_at
FROM VENDOR_MATCH_GROUPS g
JOIN VENDOR_SOURCE_RECORDS r ON r.source_vendor_id = g.source_vendor_id AND r.src_system = 'SAP'
QUALIFY ROW_NUMBER() OVER (PARTITION BY g.group_id ORDER BY IFF(r.created_by = 'SAP_MIGRATION', 0, 1), r.source_vendor_id) = 1;

CREATE OR REPLACE TABLE VENDOR_XREF AS
SELECT g.source_vendor_id, g.group_id AS golden_vendor_id, IFF(g.source_vendor_id = g.group_id, 'SURVIVOR', 'DUPLICATE') AS record_role,
       COALESCE(g.match_rule, 'Single source record') AS match_rule, COALESCE(g.confidence, 1.0) AS confidence, r.vendor_name AS source_vendor_name, r.created_by
FROM VENDOR_MATCH_GROUPS g JOIN VENDOR_SOURCE_RECORDS r ON r.source_vendor_id = g.source_vendor_id AND r.src_system = 'SAP';

-- Demo query: the 17 duplicates and the golden record they collapse to
SELECT x.source_vendor_id, x.source_vendor_name, x.created_by, x.match_rule, x.confidence, x.golden_vendor_id, v.golden_vendor_name
FROM VENDOR_XREF x JOIN VENDOR_GOLDEN v ON v.golden_vendor_id = x.golden_vendor_id
WHERE x.record_role = 'DUPLICATE' ORDER BY x.golden_vendor_id;
-- Expected: 17 rows, 97 source records -> 80 golden records.

-- ------------------------------------------------------------------ 4. Data quality
USE SCHEMA EDW_SILVER.DQ;

CREATE OR REPLACE TABLE DQ_RULES (
  rule_id VARCHAR(12), rule_name VARCHAR(80), target_object VARCHAR(120), target_column VARCHAR(60), rule_type VARCHAR(20),
  rule_expression VARCHAR(400), severity VARCHAR(10), threshold_pct NUMBER(5,2), owner VARCHAR(60), active BOOLEAN DEFAULT TRUE
);
INSERT INTO DQ_RULES (rule_id, rule_name, target_object, target_column, rule_type, rule_expression, severity, threshold_pct, owner) VALUES
 ('DQ-001', 'Invoice date parses',          'CONTRACTOR_FEED', 'INVOICE_DATE', 'VALIDITY',     'TRY_TO_DATE(INVOICE_DATE) IS NOT NULL',                       'REJECT', 0,   'Finance Data Steward'),
 ('DQ-002', 'Hours non-negative',           'CONTRACTOR_FEED', 'REG_HOURS,OT_HOURS', 'RANGE',  'REG_HOURS >= 0 AND OT_HOURS >= 0',                             'REJECT', 0,   'HR Data Steward'),
 ('DQ-003', 'Hours within monthly maximum', 'CONTRACTOR_FEED', 'REG_HOURS,OT_HOURS', 'RANGE',  'REG_HOURS + OT_HOURS <= 372',                                 'REJECT', 0,   'HR Data Steward'),
 ('DQ-004', 'Amount numeric',               'CONTRACTOR_FEED', 'AMOUNT_USD',   'VALIDITY',     'TRY_TO_NUMBER(AMOUNT_USD, 12, 2) IS NOT NULL',                 'REJECT', 0,   'Finance Data Steward'),
 ('DQ-005', 'Rate numeric',                 'CONTRACTOR_FEED', 'RATE_USD',     'VALIDITY',     'TRY_TO_NUMBER(RATE_USD, 8, 3) IS NOT NULL',                    'REJECT', 0,   'Finance Data Steward'),
 ('DQ-006', 'Contractor id present',        'CONTRACTOR_FEED', 'CONTRACTOR_ID','COMPLETENESS', 'CONTRACTOR_ID IS NOT NULL',                                    'REJECT', 0,   'HR Data Steward'),
 ('DQ-007', 'Vendor id is a known agency',  'CONTRACTOR_FEED', 'VENDOR_ID',    'REFERENTIAL',  'VENDOR_ID IN (SELECT golden_vendor_id FROM MDM.VENDOR_GOLDEN)','REJECT', 0,   'Procurement Data Steward'),
 ('DQ-008', 'Invoice line unique',          'CONTRACTOR_FEED', 'INVOICE_NO',   'UNIQUENESS',   'No repeat of an earlier line with the same INVOICE_NO',      'WARN',   0,   'Finance Data Steward'),
 ('DQ-009', 'Amount reconciles to hours x rate', 'CONTRACTOR_FEED', 'AMOUNT_USD', 'CONSISTENCY', 'ABS(AMOUNT_USD - (REG_HOURS*RATE_USD + OT_HOURS*OT_RATE_USD)) < 0.05', 'WARN', 1, 'Finance Data Steward'),
 ('DQ-010', 'Uplift id unique',             'CMS_UPLIFT_FLIGHT_CLASS', 'UPLIFT_ID', 'UNIQUENESS', 'COUNT(*) OVER (PARTITION BY UPLIFT_ID) = 1',                'WARN',   1,   'Catering Data Steward'),
 ('DQ-011', 'Carrier code upper-case IATA', 'CMS_UPLIFT_FLIGHT_CLASS', 'CARRIER', 'VALIDITY',   'CARRIER = UPPER(TRIM(CARRIER))',                               'WARN',   2,   'Catering Data Steward'),
 ('DQ-012', 'Carrier exists in airline master', 'CMS_UPLIFT_FLIGHT_CLASS', 'CARRIER', 'REFERENTIAL', 'UPPER(TRIM(CARRIER)) IN (SELECT airline_code FROM REF_AIRLINE)', 'REJECT', 0, 'Catering Data Steward'),
 ('DQ-013', 'Employee unique in SF extract','SF_EMPLOYEE_MASTER', 'PERSON_ID_EXTERNAL', 'UNIQUENESS', 'COUNT(*) OVER (PARTITION BY PERSON_ID_EXTERNAL) = 1',      'WARN',   1,   'HR Data Steward'),
 ('DQ-014', 'Vendor master duplicates',     'SAP_VENDOR_MASTER', 'LIFNR', 'UNIQUENESS',          'One SAP vendor id per CR number / IBAN',                      'WARN',   0,   'Procurement Data Steward'),
 ('DQ-015', 'GL period balanced to SAP',    'SAP_GL_ACTUALS_MONTHLY', 'DMBTR', 'RECONCILIATION', 'SUM(DMBTR) bronze = SUM(amount_usd) gold per entity/period',   'REJECT', 0,   'Group Finance');

CREATE OR REPLACE TABLE DQ_QUARANTINE (
  quarantine_id NUMBER AUTOINCREMENT, quarantined_at TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
  source_object VARCHAR(120), file_name VARCHAR(400), file_row_number NUMBER, batch_id VARCHAR(50),
  failed_rules VARCHAR(200), row_payload VARIANT, resolution_status VARCHAR(20) DEFAULT 'OPEN', resolved_by VARCHAR(60), resolved_at TIMESTAMP_NTZ
);

CREATE OR REPLACE TABLE DQ_RESULTS (
  result_id NUMBER AUTOINCREMENT, run_ts TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(), batch_id VARCHAR(50), rule_id VARCHAR(12), target_object VARCHAR(120),
  rows_checked NUMBER, rows_failed NUMBER, fail_pct NUMBER(7,3), status VARCHAR(10)
);

-- 4a. Row-level DQ on the leniently-landed malformed file (positional columns from the 12-column file)
CREATE OR REPLACE TEMPORARY TABLE _lenient_eval AS
SELECT file_name, file_row_number,
       C1 AS INVOICE_NO, C2 AS INVOICE_DATE, C3 AS VENDOR_ID, C4 AS CONTRACTOR_ID, C5 AS CONTRACTOR_NAME, C6 AS POOL_CC, C7 AS PERIOD,
       C8 AS REG_HOURS, C9 AS OT_HOURS, C10 AS RATE_USD, C11 AS AMOUNT_USD, C12 AS CURRENCY,
       ARRAY_CONSTRUCT_COMPACT(
         IFF(TRY_TO_DATE(C2, 'YYYY-MM-DD') IS NULL, 'DQ-001', NULL),
         IFF(TRY_TO_NUMBER(C8, 7, 2) < 0 OR TRY_TO_NUMBER(C9, 7, 2) < 0, 'DQ-002', NULL),
         IFF(COALESCE(TRY_TO_NUMBER(C8, 7, 2), 0) + COALESCE(TRY_TO_NUMBER(C9, 7, 2), 0) > 372, 'DQ-003', NULL),
         IFF(TRY_TO_NUMBER(C11, 12, 2) IS NULL, 'DQ-004', NULL),
         IFF(TRY_TO_NUMBER(C10, 8, 3) IS NULL, 'DQ-005', NULL),
         IFF(C4 IS NULL, 'DQ-006', NULL),
         IFF(vg.golden_vendor_id IS NULL, 'DQ-007', NULL),
         IFF(ROW_NUMBER() OVER (PARTITION BY C1 ORDER BY file_row_number) > 1, 'DQ-008', NULL),   -- repeats only; the first line of an invoice is genuine
         'DQ-STRUCT'   -- every row of this file fails the structural contract (12 of 14 columns)
       ) AS failed_rules
FROM EDW_BRONZE.QUARANTINE.CONTRACTOR_FEED_LENIENT q
LEFT JOIN EDW_SILVER.MDM.VENDOR_GOLDEN vg ON vg.golden_vendor_id = q.C3
WHERE q.file_name ILIKE '%contractor_feed_2026-09-28_malformed%';

INSERT INTO DQ_QUARANTINE (source_object, file_name, file_row_number, batch_id, failed_rules, row_payload)
SELECT 'CONTRACTOR_FEED', file_name, file_row_number, 'CONTRACTOR_20260928_001', ARRAY_TO_STRING(failed_rules, ','),
       OBJECT_CONSTRUCT('INVOICE_NO', INVOICE_NO, 'INVOICE_DATE', INVOICE_DATE, 'VENDOR_ID', VENDOR_ID, 'CONTRACTOR_ID', CONTRACTOR_ID, 'CONTRACTOR_NAME', CONTRACTOR_NAME,
                        'POOL_CC', POOL_CC, 'PERIOD', PERIOD, 'REG_HOURS', REG_HOURS, 'OT_HOURS', OT_HOURS, 'RATE_USD', RATE_USD, 'AMOUNT_USD', AMOUNT_USD, 'CURRENCY', CURRENCY)
FROM _lenient_eval;

INSERT INTO DQ_RESULTS (batch_id, rule_id, target_object, rows_checked, rows_failed, fail_pct, status)
SELECT 'CONTRACTOR_20260928_001', r.rule_id, 'CONTRACTOR_FEED (malformed file)', COUNT(*),
       SUM(IFF(ARRAY_CONTAINS(r.rule_id::VARIANT, e.failed_rules), 1, 0)),
       ROUND(100.0 * SUM(IFF(ARRAY_CONTAINS(r.rule_id::VARIANT, e.failed_rules), 1, 0)) / COUNT(*), 3),
       IFF(100.0 * SUM(IFF(ARRAY_CONTAINS(r.rule_id::VARIANT, e.failed_rules), 1, 0)) / COUNT(*) > r.threshold_pct, 'FAIL', 'PASS')
FROM _lenient_eval e CROSS JOIN DQ_RULES r
WHERE r.target_object = 'CONTRACTOR_FEED'
GROUP BY r.rule_id, r.threshold_pct;

-- 4b. Rule results on the accepted daily file and the live CMS feed (these should PASS / WARN only)
INSERT INTO DQ_RESULTS (batch_id, rule_id, target_object, rows_checked, rows_failed, fail_pct, status)
SELECT 'CONTRACTOR_20260928_002', 'DQ-002', 'CONTRACTOR_FEED_DAILY', COUNT(*), SUM(IFF(REG_HOURS < 0 OR OT_HOURS < 0, 1, 0)), 0, 'PASS' FROM EDW_BRONZE.RAW.CONTRACTOR_FEED_DAILY
UNION ALL
SELECT 'CONTRACTOR_20260928_002', 'DQ-009', 'CONTRACTOR_FEED_DAILY', COUNT(*), SUM(IFF(ABS(AMOUNT_USD - (REG_HOURS * RATE_USD + OT_HOURS * OT_RATE_USD)) >= 0.05, 1, 0)),
       ROUND(100.0 * SUM(IFF(ABS(AMOUNT_USD - (REG_HOURS * RATE_USD + OT_HOURS * OT_RATE_USD)) >= 0.05, 1, 0)) / COUNT(*), 3),
       IFF(SUM(IFF(ABS(AMOUNT_USD - (REG_HOURS * RATE_USD + OT_HOURS * OT_RATE_USD)) >= 0.05, 1, 0)) > 0.01 * COUNT(*), 'FAIL', 'PASS') FROM EDW_BRONZE.RAW.CONTRACTOR_FEED_DAILY
UNION ALL
SELECT 'CMS_202609_001', 'DQ-010', 'CMS_UPLIFT_FLIGHT_CLASS', COUNT(*), COUNT(*) - COUNT(DISTINCT UPLIFT_ID), ROUND(100.0 * (COUNT(*) - COUNT(DISTINCT UPLIFT_ID)) / COUNT(*), 3),
       IFF(100.0 * (COUNT(*) - COUNT(DISTINCT UPLIFT_ID)) / COUNT(*) > 1, 'FAIL', 'WARN') FROM EDW_BRONZE.RAW.CMS_UPLIFT_FLIGHT_CLASS
UNION ALL
SELECT 'CMS_202609_001', 'DQ-011', 'CMS_UPLIFT_FLIGHT_CLASS', COUNT(*), SUM(IFF(CARRIER <> UPPER(TRIM(CARRIER)), 1, 0)), ROUND(100.0 * SUM(IFF(CARRIER <> UPPER(TRIM(CARRIER)), 1, 0)) / COUNT(*), 3),
       IFF(100.0 * SUM(IFF(CARRIER <> UPPER(TRIM(CARRIER)), 1, 0)) / COUNT(*) > 2, 'FAIL', 'WARN') FROM EDW_BRONZE.RAW.CMS_UPLIFT_FLIGHT_CLASS
UNION ALL
SELECT 'CMS_202609_001', 'DQ-012', 'CMS_UPLIFT_FLIGHT_CLASS', COUNT(*), SUM(IFF(a.airline_code IS NULL, 1, 0)), ROUND(100.0 * SUM(IFF(a.airline_code IS NULL, 1, 0)) / COUNT(*), 3),
       IFF(SUM(IFF(a.airline_code IS NULL, 1, 0)) > 0, 'FAIL', 'PASS')
FROM EDW_BRONZE.RAW.CMS_UPLIFT_FLIGHT_CLASS c LEFT JOIN EDW_SILVER.CONFORMED.REF_AIRLINE a ON a.airline_code = UPPER(TRIM(c.CARRIER))
UNION ALL
SELECT 'SF_202609_001', 'DQ-013', 'SF_EMPLOYEE_MASTER', COUNT(*), COUNT(*) - COUNT(DISTINCT PERSON_ID_EXTERNAL), ROUND(100.0 * (COUNT(*) - COUNT(DISTINCT PERSON_ID_EXTERNAL)) / COUNT(*), 3),
       IFF(100.0 * (COUNT(*) - COUNT(DISTINCT PERSON_ID_EXTERNAL)) / COUNT(*) > 1, 'FAIL', 'WARN') FROM EDW_BRONZE.RAW.SF_EMPLOYEE_MASTER
UNION ALL
SELECT 'SAP_202609_001', 'DQ-014', 'SAP_VENDOR_MASTER', COUNT(*), SUM(IFF(record_role = 'DUPLICATE', 1, 0)), ROUND(100.0 * SUM(IFF(record_role = 'DUPLICATE', 1, 0)) / COUNT(*), 3), 'WARN'
FROM EDW_SILVER.MDM.VENDOR_XREF;

-- What the committee sees: the quarantine with the reason per row, and the scorecard
SELECT file_row_number, failed_rules, row_payload:INVOICE_DATE::STRING AS invoice_date, row_payload:REG_HOURS::STRING AS reg_hours, row_payload:OT_HOURS::STRING AS ot_hours,
       row_payload:AMOUNT_USD::STRING AS amount, row_payload:RATE_USD::STRING AS rate, row_payload:VENDOR_ID::STRING AS vendor_id
FROM DQ_QUARANTINE WHERE failed_rules <> 'DQ-STRUCT' ORDER BY file_row_number;

SELECT r.rule_id, d.rule_name, r.target_object, r.rows_checked, r.rows_failed, r.fail_pct, r.status
FROM DQ_RESULTS r JOIN DQ_RULES d USING (rule_id) ORDER BY r.run_ts, r.rule_id;
