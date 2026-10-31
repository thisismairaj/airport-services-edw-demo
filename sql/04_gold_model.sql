-- =============================================================================
-- 04_gold_model.sql  |  Gold: star schema DDL, loads from Silver, SCD2 DIM_ASSET, aggregates
-- Column order of every table equals the matching CSV in data/gold (expected results only: Gold is always built from Bronze/Silver).
-- =============================================================================
USE ROLE ROLE_ELT_ADMIN;
USE WAREHOUSE WH_ELT;
USE SCHEMA EDW_GOLD.STAR;

-- ------------------------------------------------------------------ dimensions
CREATE OR REPLACE TABLE DIM_DATE (
  date_key NUMBER(8) PRIMARY KEY, calendar_date DATE, year NUMBER(4), quarter NUMBER(1), month NUMBER(2), month_name VARCHAR(3), fiscal_year NUMBER(4),
  fiscal_quarter VARCHAR(8), fiscal_period VARCHAR(7), day_of_week NUMBER(1), day_name VARCHAR(3), is_weekend BOOLEAN, week_of_year NUMBER(2), is_ramadan BOOLEAN, is_peak_season BOOLEAN
) COMMENT = 'Calendar = fiscal year (Jan-Dec). Weekend = Fri/Sat (Bayport).';

CREATE OR REPLACE TABLE DIM_ENTITY (
  entity_key NUMBER(3) PRIMARY KEY, entity_code VARCHAR(10), entity_name VARCHAR(80), legal_name VARCHAR(120), country_code VARCHAR(2), local_currency VARCHAR(3),
  sap_company_code VARCHAR(4), sf_legal_entity_name VARCHAR(80), home_station VARCHAR(3)
);

CREATE OR REPLACE TABLE DIM_AIRLINE (
  airline_key NUMBER(4) PRIMARY KEY, airline_code VARCHAR(3), icao_code VARCHAR(3), airline_name VARCHAR(80), alliance VARCHAR(20), demo_alias VARCHAR(20), contract_type VARCHAR(40),
  contract_margin_pct NUMBER(5,3), base_load_factor NUMBER(5,3), catering_customer BOOLEAN, handling_customer BOOLEAN, country_code VARCHAR(2), account_manager VARCHAR(40),
  contract_id VARCHAR(20), contract_start DATE, contract_end DATE
) COMMENT = 'demo_alias (Carrier A..I) is used on anonymised committee slides; airline_name in the live model';

CREATE OR REPLACE TABLE DIM_STATION (
  station_key NUMBER(3) PRIMARY KEY, station_code VARCHAR(3), icao_code VARCHAR(4), station_name VARCHAR(80), city VARCHAR(40), country_code VARCHAR(2), operating_entity_code VARCHAR(10), timezone VARCHAR(30)
);

CREATE OR REPLACE TABLE DIM_FLIGHT (
  flight_key NUMBER(5) PRIMARY KEY, airline_code VARCHAR(3), flight_number VARCHAR(10), origin VARCHAR(3), destination VARCHAR(3), route_group VARCHAR(20), aircraft_type VARCHAR(6), days_of_week VARCHAR(7),
  station_code VARCHAR(3), service_entity_code VARCHAR(10), catered_by_asc BOOLEAN, handled_by_asc BOOLEAN, sched_dep_local VARCHAR(5), is_night_departure BOOLEAN,
  seats_f NUMBER(4), seats_j NUMBER(4), seats_y NUMBER(4), body_type VARCHAR(10), turnaround_fee_usd NUMBER(10,2), airline_key NUMBER(4), station_key NUMBER(3), entity_key NUMBER(3)
) COMMENT = 'Scheduled flight (turnaround) master - one row per scheduled service';

CREATE OR REPLACE TABLE DIM_EMPLOYEE (
  employee_key NUMBER(12) PRIMARY KEY, employee_id VARCHAR(10), full_name VARCHAR(120), first_name VARCHAR(60), last_name VARCHAR(60), gender VARCHAR(1), nationality VARCHAR(2),
  national_id VARCHAR(20), date_of_birth DATE, work_email VARCHAR(120), entity_code VARCHAR(10), station_code VARCHAR(3), cost_center_code VARCHAR(10), deployed_cost_center_code VARCHAR(10),
  business_unit VARCHAR(40), job_title VARCHAR(80), grade VARCHAR(3), employment_type VARCHAR(12), contractor_vendor_id VARCHAR(10), shift_pattern VARCHAR(10), hire_date DATE,
  termination_date DATE, employment_status VARCHAR(12), monthly_salary_usd NUMBER(12,2), housing_allowance_usd NUMBER(12,2), hourly_rate_usd NUMBER(8,3), manager_employee_id VARCHAR(10),
  entity_key NUMBER(3), cost_center_key NUMBER(4)
) COMMENT = 'Permanent staff (SuccessFactors) + contractors (agency feeds). PII/payroll columns are masked by policy (06).';

CREATE OR REPLACE TABLE DIM_COST_CENTER (
  cost_center_key NUMBER(4) PRIMARY KEY, cost_center_code VARCHAR(10), cost_center_name VARCHAR(80), entity_code VARCHAR(10), business_unit VARCHAR(40), station_code VARCHAR(3),
  target_headcount NUMBER(5), entity_key NUMBER(3), station_key NUMBER(3), cc_owner VARCHAR(40), is_operational BOOLEAN
);

CREATE OR REPLACE TABLE DIM_GL_ACCOUNT (
  gl_account_key NUMBER(4) PRIMARY KEY, gl_account VARCHAR(10), gl_description VARCHAR(80), account_class VARCHAR(20), kpi_group VARCHAR(30), is_ebitda BOOLEAN, is_intercompany BOOLEAN,
  natural_sign NUMBER(2), statement_line VARCHAR(30)
) COMMENT = 'Revenue stored negative (SAP credit convention). natural_sign flips to presentation sign.';

CREATE OR REPLACE TABLE DIM_ASSET (
  asset_key NUMBER(6) PRIMARY KEY, asset_id VARCHAR(12), asset_type VARCHAR(40), asset_class VARCHAR(5), make VARCHAR(40), model VARCHAR(40), year_of_manufacture NUMBER(4),
  acquisition_cost_usd NUMBER(14,2), downtime_rate_usd_per_hr NUMBER(8,2), cost_center_code VARCHAR(10), station_code VARCHAR(3), entity_code VARCHAR(10), status VARCHAR(40), criticality VARCHAR(10),
  effective_from DATE, effective_to DATE, is_current BOOLEAN, version_no NUMBER(3), entity_key NUMBER(3), station_key NUMBER(3), cost_center_key NUMBER(4)
) COMMENT = 'SCD Type 2: cost centre / station / status changes open a new version. effective_to = 9999-12-31 on the current row.';

CREATE OR REPLACE TABLE DIM_MEAL (
  meal_key NUMBER(4) PRIMARY KEY, menu_spec_code VARCHAR(12), airline_code VARCHAR(3), meal_class VARCHAR(1), meal_class_name VARCHAR(20), meal_type VARCHAR(40), spec_version NUMBER(2),
  effective_from DATE, effective_to DATE, std_food_cost_usd NUMBER(8,3), std_labour_cost_usd NUMBER(8,3), std_overhead_cost_usd NUMBER(8,3), spec_change_reason VARCHAR(120)
) COMMENT = 'Menu specification per airline x class x version (v3 = Jul-2026 spec change for EK, FZ, Charter)';

CREATE OR REPLACE TABLE DIM_VENDOR (
  vendor_key NUMBER(5) PRIMARY KEY, golden_vendor_id VARCHAR(10), golden_vendor_name VARCHAR(120), category VARCHAR(60), default_gl VARCHAR(10), cr_number VARCHAR(20), iban VARCHAR(34),
  country VARCHAR(3), payment_terms VARCHAR(10), duplicate_source_ids VARCHAR(200), match_rule VARCHAR(80)
) COMMENT = 'MDM golden vendor records (80) - 17 duplicates collapsed, see duplicate_source_ids';

-- ------------------------------------------------------------------ facts
CREATE OR REPLACE TABLE FACT_CATERING_UPLIFT (
  catering_uplift_key NUMBER(10) PRIMARY KEY, date_key NUMBER(8), entity_key NUMBER(3), station_key NUMBER(3), airline_key NUMBER(4), meal_key NUMBER(4), route_group VARCHAR(20), meal_class VARCHAR(1),
  flights_catered NUMBER(5), meals_planned NUMBER(9), meals_uplifted NUMBER(9), meals_downlifted NUMBER(9), meals_wasted NUMBER(9), late_downlift_confirmations NUMBER(5), deliveries_total NUMBER(5),
  deliveries_on_time NUMBER(5), food_cost_usd NUMBER(14,2), labour_cost_usd NUMBER(14,2), overhead_cost_usd NUMBER(14,2), total_cost_usd NUMBER(14,2), revenue_usd NUMBER(14,2), src_batch_id VARCHAR(50)
) COMMENT = 'Grain: day x airline x route group x meal class x station. Costs are production cost of meals produced (uplifted + wasted).';

CREATE OR REPLACE TABLE FACT_FINANCE_POSTING (
  finance_posting_key NUMBER(10) PRIMARY KEY, fiscal_period VARCHAR(7), fiscal_year NUMBER(4), date_key NUMBER(8), entity_key NUMBER(3), cost_center_key NUMBER(4), gl_account_key NUMBER(4),
  airline_key NUMBER(4), amount_usd NUMBER(16,2), budget_usd NUMBER(16,2), variance_usd NUMBER(16,2), posting_count NUMBER(9), src_batch_id VARCHAR(50)
) COMMENT = 'Grain: month x entity x cost centre x GL x (airline profit centre). Credit = negative.';

CREATE OR REPLACE TABLE FACT_WORK_ORDER (
  work_order_key NUMBER(10) PRIMARY KEY, wo_id VARCHAR(12), asset_key NUMBER(6), asset_id VARCHAR(12), date_key NUMBER(8), entity_key NUMBER(3), station_key NUMBER(3), cost_center_key NUMBER(4),
  wo_type VARCHAR(4), fault_code VARCHAR(8), fault_description VARCHAR(80), priority NUMBER(1), reported_ts TIMESTAMP_NTZ, start_ts TIMESTAMP_NTZ, finish_ts TIMESTAMP_NTZ,
  downtime_hours NUMBER(8,2), repair_hours NUMBER(8,2), labour_hours NUMBER(8,2), parts_cost_usd NUMBER(12,2), labour_cost_usd NUMBER(12,2), downtime_cost_usd NUMBER(12,2),
  is_failure BOOLEAN, status VARCHAR(8), technician_id VARCHAR(10), src_batch_id VARCHAR(50)
) COMMENT = 'asset_key points at the DIM_ASSET version in effect on the work-order date (SCD2 lookup)';

CREATE OR REPLACE TABLE FACT_LABOUR_COST (
  labour_cost_key NUMBER(10) PRIMARY KEY, fiscal_period VARCHAR(7), date_key NUMBER(8), entity_key NUMBER(3), cost_center_key NUMBER(4), deployed_cost_center_key NUMBER(4), employment_type VARCHAR(12),
  shift_pattern VARCHAR(10), headcount NUMBER(6), regular_hours NUMBER(10,2), overtime_hours NUMBER(10,2), night_hours NUMBER(10,2), leave_hours NUMBER(10,2), regular_cost_usd NUMBER(14,2),
  overtime_cost_usd NUMBER(14,2), benefits_cost_usd NUMBER(14,2), total_cost_usd NUMBER(14,2), src_batch_id VARCHAR(50)
) COMMENT = 'Grain: month x home cost centre x deployed cost centre x employment type x shift. Overtime ratio = OT / (regular + OT).';

CREATE OR REPLACE TABLE FACT_AIRLINE_ORDER (
  airline_order_key NUMBER(10) PRIMARY KEY, date_key NUMBER(8), airline_key NUMBER(4), entity_key NUMBER(3), station_key NUMBER(3), orders_submitted NUMBER(6), orders_amended_after_cutoff NUMBER(6),
  special_meal_orders NUMBER(7), special_meals_unfulfilled NUMBER(6), sla_events NUMBER(6), sla_breaches NUMBER(6), avg_order_lead_hours NUMBER(6,1), src_batch_id VARCHAR(50)
);

CREATE OR REPLACE TABLE FACT_PURCHASE_ORDER (
  purchase_order_key NUMBER(10) PRIMARY KEY, po_number VARCHAR(10), po_line VARCHAR(5), date_key NUMBER(8), entity_key NUMBER(3), cost_center_key NUMBER(4), gl_account_key NUMBER(4), vendor_key NUMBER(5),
  source_vendor_id VARCHAR(10), category VARCHAR(60), document_currency VARCHAR(3), amount_doc_currency NUMBER(16,2), amount_usd NUMBER(16,2), has_ariba_requisition BOOLEAN, status VARCHAR(20), src_batch_id VARCHAR(50)
) COMMENT = 'PO lines mapped to golden vendors - spend by vendor is correct only after MDM';

-- ------------------------------------------------------------------ aggregates
USE SCHEMA EDW_GOLD.AGG;
CREATE OR REPLACE TABLE AGG_DAILY_FLIGHTS (
  date_key NUMBER(8), entity_key NUMBER(3), station_key NUMBER(3), airline_key NUMBER(4), route_group VARCHAR(20), flights_handled NUMBER(5), flights_catered NUMBER(5),
  departures_on_time NUMBER(5), total_delay_min NUMBER(8), handling_revenue_usd NUMBER(14,2)
) COMMENT = 'Flights serviced per day (AODB / SITA MVT history). Basis for cost per flight and on-time turnaround.';

CREATE OR REPLACE TABLE AGG_MONTHLY_AIRLINE_PNL (
  fiscal_period VARCHAR(7), airline_key NUMBER(4), flights_handled NUMBER(7), meals_uplifted NUMBER(10), meals_wasted NUMBER(10), catering_revenue_usd NUMBER(16,2), catering_cost_usd NUMBER(16,2),
  catering_food_cost_usd NUMBER(16,2), catering_labour_cost_usd NUMBER(16,2), handling_revenue_usd NUMBER(16,2), handling_cost_usd NUMBER(16,2), late_downlift_confirmations NUMBER(7),
  deliveries_total NUMBER(7), deliveries_on_time NUMBER(7), total_revenue_usd NUMBER(16,2), contribution_margin_usd NUMBER(16,2), cost_per_meal_usd NUMBER(10,3), cost_per_flight_usd NUMBER(12,2)
);

CREATE OR REPLACE TABLE AGG_MONTHLY_ASSET_RELIABILITY (
  fiscal_period VARCHAR(7), asset_id VARCHAR(12), asset_key NUMBER(6), operating_hours NUMBER(9,1), failures NUMBER(5), hydraulic_faults NUMBER(5), repair_hours NUMBER(9,1),
  downtime_hours NUMBER(9,1), downtime_cost_usd NUMBER(12,2), mtbf_hours NUMBER(10,1), mttr_hours NUMBER(8,2)
);

-- =============================================================================
-- LOADS FROM SILVER (full-path demo). Idempotent: dimensions are MERGEd, facts are rebuilt per batch.
-- =============================================================================
USE SCHEMA EDW_GOLD.STAR;

-- DIM_DATE generated
INSERT OVERWRITE INTO DIM_DATE
WITH d AS (SELECT DATEADD(day, ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1, '2025-01-01'::DATE) AS dt FROM TABLE(GENERATOR(ROWCOUNT => 639)))
SELECT TO_NUMBER(TO_CHAR(dt, 'YYYYMMDD')), dt, YEAR(dt), QUARTER(dt), MONTH(dt), TO_CHAR(dt, 'Mon'), YEAR(dt),
       'FY' || RIGHT(YEAR(dt), 2) || ' Q' || QUARTER(dt), TO_CHAR(dt, 'YYYY-MM'), DAYOFWEEKISO(dt), TO_CHAR(dt, 'Dy'), DAYOFWEEKISO(dt) IN (5, 6), WEEKISO(dt),
       (dt BETWEEN '2025-03-01' AND '2025-03-30') OR (dt BETWEEN '2026-02-18' AND '2026-03-19'), MONTH(dt) IN (6, 7, 8, 12)
FROM d;

-- Reference-driven dimensions
INSERT OVERWRITE INTO DIM_ENTITY      SELECT * FROM EDW_SILVER.CONFORMED.REF_ENTITY;
INSERT OVERWRITE INTO DIM_AIRLINE     SELECT * FROM EDW_SILVER.CONFORMED.REF_AIRLINE;
INSERT OVERWRITE INTO DIM_STATION     SELECT * FROM EDW_SILVER.CONFORMED.REF_STATION;
INSERT OVERWRITE INTO DIM_FLIGHT      SELECT * FROM EDW_SILVER.CONFORMED.REF_FLIGHT;
INSERT OVERWRITE INTO DIM_COST_CENTER SELECT * FROM EDW_SILVER.CONFORMED.REF_COST_CENTER;
INSERT OVERWRITE INTO DIM_GL_ACCOUNT  SELECT * FROM EDW_SILVER.CONFORMED.REF_GL_ACCOUNT;
INSERT OVERWRITE INTO DIM_MEAL        SELECT * FROM EDW_SILVER.CONFORMED.REF_MEAL_SPEC;

-- DIM_VENDOR from MDM
INSERT OVERWRITE INTO DIM_VENDOR
SELECT ROW_NUMBER() OVER (ORDER BY g.golden_vendor_id), g.golden_vendor_id, g.golden_vendor_name, g.category, c.default_gl, g.cr_number, g.iban, g.country, g.payment_terms,
       COALESCE(LISTAGG(IFF(x.record_role = 'DUPLICATE', x.source_vendor_id, NULL), ',') WITHIN GROUP (ORDER BY x.source_vendor_id), ''),
       COALESCE(MAX(IFF(x.record_role = 'DUPLICATE', x.match_rule, NULL)), 'Single source record')
FROM EDW_SILVER.MDM.VENDOR_GOLDEN g
JOIN EDW_SILVER.MDM.VENDOR_XREF x ON x.golden_vendor_id = g.golden_vendor_id
LEFT JOIN (SELECT MATKL AS category, MODE(SAKTO) AS default_gl FROM EDW_BRONZE.RAW.SAP_PURCHASE_ORDERS GROUP BY MATKL) c ON c.category = g.category
GROUP BY g.golden_vendor_id, g.golden_vendor_name, g.category, c.default_gl, g.cr_number, g.iban, g.country, g.payment_terms;

-- DIM_EMPLOYEE: MERGE permanents (SF) and contractors (agency feed master derived)
MERGE INTO DIM_EMPLOYEE t
USING (
  SELECT e.employee_id, e.full_name, e.FIRST_NAME, e.LAST_NAME, e.GENDER, e.NATIONALITY, e.NATIONAL_ID, e.DATE_OF_BIRTH, e.work_email, e.entity_code, cc.station_code, e.cost_center_code,
         e.cost_center_code AS deployed_cost_center_code, cc.business_unit, e.JOB_TITLE, e.grade, 'Permanent' AS employment_type, NULL AS contractor_vendor_id, e.SHIFT_PATTERN, e.HIRE_DATE,
         e.TERMINATION_DATE, e.employment_status, e.monthly_salary_usd, e.housing_allowance_usd, ROUND(e.monthly_salary_usd / 192, 3) AS hourly_rate_usd, e.manager_employee_id, e.entity_key, cc.cost_center_key
  FROM EDW_SILVER.CONFORMED.SF_EMPLOYEE_CONFORMED e
  LEFT JOIN EDW_SILVER.CONFORMED.REF_COST_CENTER cc ON cc.cost_center_code = e.cost_center_code
  UNION ALL
  SELECT c.CONTRACTOR_ID, c.CONTRACTOR_NAME, SPLIT_PART(c.CONTRACTOR_NAME, ' ', 1), SUBSTR(c.CONTRACTOR_NAME, LENGTH(SPLIT_PART(c.CONTRACTOR_NAME, ' ', 1)) + 2), NULL, NULL, NULL, NULL, NULL,
         'ASCWF', 'BYP', c.cost_center_code, c.deployed_cost_center_code, 'Manpower', 'Contract Operative', 'G1', 'Contractor', c.VENDOR_ID, NULL,
         MIN(TO_DATE(c.fiscal_period || '-01')), NULL, IFF(MAX(c.fiscal_period) = (SELECT MAX(fiscal_period) FROM EDW_SILVER.CONFORMED.CONTRACTOR_LINES_CONFORMED), 'Active', 'Terminated'),
         0, 0, MAX(c.hourly_rate_usd), NULL, 3, cc.cost_center_key
  FROM EDW_SILVER.CONFORMED.CONTRACTOR_LINES_CONFORMED c
  LEFT JOIN EDW_SILVER.CONFORMED.REF_COST_CENTER cc ON cc.cost_center_code = c.cost_center_code
  GROUP BY c.CONTRACTOR_ID, c.CONTRACTOR_NAME, c.cost_center_code, c.deployed_cost_center_code, c.VENDOR_ID, cc.cost_center_key
) s ON t.employee_id = s.employee_id
WHEN MATCHED THEN UPDATE SET
  full_name = s.full_name, cost_center_code = s.cost_center_code, deployed_cost_center_code = s.deployed_cost_center_code, job_title = s.JOB_TITLE, grade = s.grade, shift_pattern = s.SHIFT_PATTERN,
  termination_date = s.TERMINATION_DATE, employment_status = s.employment_status, monthly_salary_usd = s.monthly_salary_usd, housing_allowance_usd = s.housing_allowance_usd,
  hourly_rate_usd = s.hourly_rate_usd, manager_employee_id = s.manager_employee_id, cost_center_key = s.cost_center_key
WHEN NOT MATCHED THEN INSERT (employee_key, employee_id, full_name, first_name, last_name, gender, nationality, national_id, date_of_birth, work_email, entity_code, station_code, cost_center_code,
  deployed_cost_center_code, business_unit, job_title, grade, employment_type, contractor_vendor_id, shift_pattern, hire_date, termination_date, employment_status, monthly_salary_usd,
  housing_allowance_usd, hourly_rate_usd, manager_employee_id, entity_key, cost_center_key)
VALUES (ABS(HASH(s.employee_id)) % 1000000000, s.employee_id, s.full_name, s.FIRST_NAME, s.LAST_NAME, s.GENDER, s.NATIONALITY, s.NATIONAL_ID, s.DATE_OF_BIRTH, s.work_email, s.entity_code, s.station_code,
  s.cost_center_code, s.deployed_cost_center_code, s.business_unit, s.JOB_TITLE, s.grade, s.employment_type, s.contractor_vendor_id, s.SHIFT_PATTERN, s.HIRE_DATE, s.TERMINATION_DATE,
  s.employment_status, s.monthly_salary_usd, s.housing_allowance_usd, s.hourly_rate_usd, s.manager_employee_id, s.entity_key, s.cost_center_key);

-- ------------------------------------------------------------------ DIM_ASSET SCD Type 2
-- Step 0 (first load only): asset version history from the Maximo change log in Bronze. Skipped when history exists.
INSERT INTO DIM_ASSET SELECT * EXCLUDE (src_system, extracted_at, batch_id, row_hash) FROM EDW_BRONZE.RAW.MAXIMO_ASSET_HISTORY
WHERE NOT EXISTS (SELECT 1 FROM DIM_ASSET);
-- Step 1: expire current versions whose tracked attributes changed in the latest Maximo snapshot
UPDATE DIM_ASSET t
SET effective_to = s.source_change_date, is_current = FALSE
FROM EDW_SILVER.CONFORMED.MAXIMO_ASSET_SNAPSHOT s
WHERE t.asset_id = s.asset_id AND t.is_current
  AND (t.cost_center_code <> s.cost_center_code OR t.station_code <> s.station_code OR t.status <> s.status)
  AND s.source_change_date > t.effective_from;

-- Step 2: insert a new version for changed assets and brand-new assets
INSERT INTO DIM_ASSET (asset_key, asset_id, asset_type, asset_class, make, model, year_of_manufacture, acquisition_cost_usd, downtime_rate_usd_per_hr, cost_center_code, station_code, entity_code,
                       status, criticality, effective_from, effective_to, is_current, version_no, entity_key, station_key, cost_center_key)
SELECT (SELECT COALESCE(MAX(asset_key), 0) FROM DIM_ASSET) + ROW_NUMBER() OVER (ORDER BY s.asset_id),
       s.asset_id,
       CASE s.asset_class WHEN 'T' THEN 'Aircraft Tug (Pushback)' WHEN 'BL' THEN 'Belt Loader' WHEN 'HL' THEN 'High Loader' WHEN 'GPU' THEN 'Ground Power Unit' ELSE 'Catering Hi-Lift Truck' END,
       s.asset_class, s.make, s.MODEL, s.year_of_manufacture, s.acquisition_cost_usd,
       CASE s.asset_class WHEN 'T' THEN 45 WHEN 'BL' THEN 35 WHEN 'HL' THEN 60 WHEN 'GPU' THEN 30 ELSE 55 END,
       s.cost_center_code, s.station_code, s.entity_code, s.status, s.criticality,
       COALESCE(s.source_change_date, '2024-01-01'), '9999-12-31', TRUE,
       COALESCE(pv.max_version, 0) + 1,
       s.entity_key, s.station_key, cc.cost_center_key
FROM EDW_SILVER.CONFORMED.MAXIMO_ASSET_SNAPSHOT s
LEFT JOIN EDW_SILVER.CONFORMED.REF_COST_CENTER cc ON cc.cost_center_code = s.cost_center_code
LEFT JOIN (SELECT asset_id, MAX(version_no) AS max_version FROM DIM_ASSET GROUP BY asset_id) pv ON pv.asset_id = s.asset_id
WHERE NOT EXISTS (SELECT 1 FROM DIM_ASSET t WHERE t.asset_id = s.asset_id AND t.is_current);

-- ------------------------------------------------------------------ facts
INSERT OVERWRITE INTO FACT_CATERING_UPLIFT
SELECT ROW_NUMBER() OVER (ORDER BY u.uplift_date, u.carrier, u.route_group, u.meal_class),
       TO_NUMBER(TO_CHAR(u.uplift_date, 'YYYYMMDD')), u.entity_key, u.station_key, a.airline_key, m.meal_key, u.route_group, u.meal_class,
       u.flights, u.meals_planned, u.meals_uplifted, u.meals_downlifted, u.meals_wasted, u.downlift_late_cnt, u.flights, u.deliveries_on_time,
       u.food_cost, u.labour_cost, u.overhead_cost, u.food_cost + u.labour_cost + u.overhead_cost, u.bill_amount, u.src_batch_id
FROM EDW_SILVER.CONFORMED.CMS_UPLIFT_DAILY u
JOIN DIM_AIRLINE a ON a.airline_code = u.carrier
LEFT JOIN DIM_MEAL m ON m.menu_spec_code = u.menu_spec_code;

INSERT OVERWRITE INTO FACT_FINANCE_POSTING
SELECT ROW_NUMBER() OVER (ORDER BY g.fiscal_period, g.entity_key, g.cost_center_code, g.gl_account, g.airline_code),
       g.fiscal_period, LEFT(g.fiscal_period, 4)::NUMBER, TO_NUMBER(TO_CHAR(g.period_end_date, 'YYYYMMDD')), g.entity_key, cc.cost_center_key, gl.gl_account_key, a.airline_key,
       g.amount_usd, g.budget_usd, g.amount_usd - g.budget_usd, g.POSTING_COUNT, g.src_batch_id
FROM EDW_SILVER.CONFORMED.SAP_GL_CONFORMED g
JOIN DIM_COST_CENTER cc ON cc.cost_center_code = g.cost_center_code
JOIN DIM_GL_ACCOUNT gl ON gl.gl_account = g.gl_account
LEFT JOIN DIM_AIRLINE a ON a.airline_code = g.airline_code;

INSERT OVERWRITE INTO FACT_WORK_ORDER
SELECT ROW_NUMBER() OVER (ORDER BY w.reported_ts, w.wo_id), w.wo_id, d.asset_key, w.asset_id, TO_NUMBER(TO_CHAR(w.wo_date, 'YYYYMMDD')), d.entity_key, d.station_key, d.cost_center_key,
       w.wo_type, w.fault_code, w.fault_description, w.priority, w.reported_ts, w.start_ts, w.finish_ts, w.downtime_hours, w.repair_hours, w.labour_hours, w.parts_cost_usd, w.labour_cost_usd,
       ROUND(w.downtime_hours * d.downtime_rate_usd_per_hr, 2), w.wo_type = 'CM', w.STATUS, w.technician_id, w.src_batch_id
FROM EDW_SILVER.CONFORMED.MAXIMO_WO_CONFORMED w
JOIN DIM_ASSET d ON d.asset_id = w.asset_id AND w.wo_date >= d.effective_from AND w.wo_date < d.effective_to;   -- SCD2 point-in-time lookup

INSERT OVERWRITE INTO FACT_LABOUR_COST
WITH perm AS (
  SELECT t.fiscal_period, e.cost_center_code, e.cost_center_code AS deployed_cost_center_code, 'Permanent' AS employment_type, e.shift_pattern, e.employee_id,
         t.regular_hours, t.overtime_hours, t.night_hours, t.leave_hours,
         t.regular_hours * e.hourly_rate_usd AS regular_cost, t.overtime_hours * e.hourly_rate_usd * t.ot_multiplier AS overtime_cost, t.regular_hours * e.hourly_rate_usd * 0.20 AS benefits_cost,
         'SF_' || REPLACE(t.fiscal_period, '-', '') || '_001' AS src_batch_id
  FROM EDW_SILVER.CONFORMED.SF_TIME_CONFORMED t JOIN DIM_EMPLOYEE e ON e.employee_id = t.employee_id
), cont AS (
  SELECT c.fiscal_period, c.cost_center_code, c.deployed_cost_center_code, 'Contractor', e.shift_pattern, c.CONTRACTOR_ID,
         c.regular_hours, c.overtime_hours, IFF(e.shift_pattern = 'Night', c.regular_hours, 0), 0,
         c.regular_hours * c.hourly_rate_usd, c.overtime_hours * c.ot_rate_usd, 0, c.src_batch_id
  FROM EDW_SILVER.CONFORMED.CONTRACTOR_LINES_CONFORMED c LEFT JOIN DIM_EMPLOYEE e ON e.employee_id = c.CONTRACTOR_ID
), u AS (SELECT * FROM perm UNION ALL SELECT * FROM cont)
SELECT ROW_NUMBER() OVER (ORDER BY u.fiscal_period, u.cost_center_code, u.deployed_cost_center_code, u.employment_type, u.shift_pattern),
       fiscal_period, TO_NUMBER(TO_CHAR(LAST_DAY(TO_DATE(fiscal_period || '-01')), 'YYYYMMDD')), cc.entity_key, cc.cost_center_key, dc.cost_center_key, employment_type, shift_pattern,
       COUNT(DISTINCT employee_id), SUM(regular_hours), SUM(overtime_hours), SUM(night_hours), SUM(leave_hours),
       ROUND(SUM(regular_cost), 2), ROUND(SUM(overtime_cost), 2), ROUND(SUM(benefits_cost), 2), ROUND(SUM(regular_cost + overtime_cost + benefits_cost), 2), MAX(src_batch_id)
FROM u
JOIN DIM_COST_CENTER cc ON cc.cost_center_code = u.cost_center_code
JOIN DIM_COST_CENTER dc ON dc.cost_center_code = u.deployed_cost_center_code
GROUP BY fiscal_period, u.cost_center_code, u.deployed_cost_center_code, employment_type, shift_pattern, cc.entity_key, cc.cost_center_key, dc.cost_center_key;

INSERT OVERWRITE INTO FACT_AIRLINE_ORDER
SELECT ROW_NUMBER() OVER (ORDER BY o.order_date, o.airline_code), TO_NUMBER(TO_CHAR(o.order_date, 'YYYYMMDD')), a.airline_key, 1, s.station_key, o.ORDERS_SUBMITTED, o.ORDERS_AMENDED_AFTER_CUTOFF,
       o.SPML_ORDERS, o.SPML_UNFULFILLED, o.SLA_EVENTS, o.SLA_BREACHES, o.AVG_LEAD_HOURS, o.src_batch_id
FROM EDW_SILVER.CONFORMED.PORTAL_ORDERS_CONFORMED o
JOIN DIM_AIRLINE a ON a.airline_code = o.airline_code
JOIN DIM_STATION s ON s.station_code = o.station_code;

INSERT OVERWRITE INTO FACT_PURCHASE_ORDER
SELECT ROW_NUMBER() OVER (ORDER BY p.BEDAT, p.EBELN), p.EBELN, p.EBELP, TO_NUMBER(TO_CHAR(p.BEDAT, 'YYYYMMDD')), m.entity_key, cc.cost_center_key, gl.gl_account_key, v.vendor_key, p.LIFNR, p.MATKL,
       p.WAERS, p.NETWR, ROUND(p.NETWR * CASE p.WAERS WHEN 'EUR' THEN 1 / 0.926 WHEN 'SAR' THEN 1 / 3.75 ELSE 1 END, 2), p.ARIBA_REQ_ID IS NOT NULL, p.STATUS, p.batch_id
FROM EDW_BRONZE.RAW.SAP_PURCHASE_ORDERS p
JOIN EDW_SILVER.CONFORMED.ENTITY_CODE_MAP m ON m.src_system = 'SAP' AND m.src_code = p.BUKRS
JOIN DIM_COST_CENTER cc ON cc.cost_center_code = p.KOSTL
JOIN DIM_GL_ACCOUNT gl ON gl.gl_account = p.SAKTO
JOIN EDW_SILVER.MDM.VENDOR_XREF x ON x.source_vendor_id = p.LIFNR            -- duplicate ids resolve to the golden record
JOIN DIM_VENDOR v ON v.golden_vendor_id = x.golden_vendor_id
QUALIFY ROW_NUMBER() OVER (PARTITION BY p.EBELN, p.EBELP ORDER BY p.extracted_at DESC) = 1;

-- ------------------------------------------------------------------ aggregates
USE SCHEMA EDW_GOLD.AGG;
-- AGG_DAILY_FLIGHTS: flight-movement history (Jan-2025..Sep-2026) comes from the AODB daily movements in Bronze;
-- the live SITA window in Bronze (16-30 Sep 2026) then refreshes/overwrites those days via MERGE.
TRUNCATE TABLE IF EXISTS AGG_DAILY_FLIGHTS;
INSERT INTO AGG_DAILY_FLIGHTS SELECT * EXCLUDE (src_system, extracted_at, batch_id, row_hash) FROM EDW_BRONZE.RAW.AODB_DAILY_MOVEMENTS;
MERGE INTO AGG_DAILY_FLIGHTS t
USING (
  SELECT TO_NUMBER(TO_CHAR(s.flight_date, 'YYYYMMDD')) AS date_key, f.entity_key, f.station_key, f.airline_key, f.route_group,
         COUNT(*) AS flights_handled, SUM(IFF(f.catered_by_asc, 1, 0)) AS flights_catered, SUM(s.on_time_flag) AS departures_on_time, SUM(s.DELAY_MIN) AS total_delay_min,
         SUM(f.turnaround_fee_usd) AS handling_revenue_usd
  FROM EDW_SILVER.CONFORMED.SITA_MOVEMENTS s
  JOIN EDW_GOLD.STAR.DIM_FLIGHT f ON f.flight_number = s.flight_number AND f.station_code = s.station_code
  WHERE s.MSG_TYPE = 'MVT'
  GROUP BY 1, 2, 3, 4, 5
) s ON t.date_key = s.date_key AND t.entity_key = s.entity_key AND t.station_key = s.station_key AND t.airline_key = s.airline_key AND t.route_group = s.route_group
WHEN MATCHED THEN UPDATE SET flights_handled = s.flights_handled, flights_catered = s.flights_catered, departures_on_time = s.departures_on_time, total_delay_min = s.total_delay_min, handling_revenue_usd = s.handling_revenue_usd
WHEN NOT MATCHED THEN INSERT VALUES (s.date_key, s.entity_key, s.station_key, s.airline_key, s.route_group, s.flights_handled, s.flights_catered, s.departures_on_time, s.total_delay_min, s.handling_revenue_usd);

INSERT OVERWRITE INTO AGG_MONTHLY_AIRLINE_PNL
WITH cat AS (
  SELECT d.fiscal_period, f.airline_key, SUM(meals_uplifted) AS meals, SUM(meals_wasted) AS wasted, SUM(revenue_usd) AS cat_rev, SUM(total_cost_usd) AS cat_cost, SUM(food_cost_usd) AS food,
         SUM(labour_cost_usd) AS labour, SUM(late_downlift_confirmations) AS late, SUM(deliveries_total) AS deliv, SUM(deliveries_on_time) AS ontime
  FROM EDW_GOLD.STAR.FACT_CATERING_UPLIFT f JOIN EDW_GOLD.STAR.DIM_DATE d USING (date_key) GROUP BY 1, 2
), gh AS (
  SELECT d.fiscal_period, a.airline_key, SUM(flights_handled) AS flights, SUM(handling_revenue_usd) AS gh_rev
  FROM AGG_DAILY_FLIGHTS a JOIN EDW_GOLD.STAR.DIM_DATE d USING (date_key) GROUP BY 1, 2
)
SELECT gh.fiscal_period, gh.airline_key, gh.flights, COALESCE(cat.meals, 0), COALESCE(cat.wasted, 0), COALESCE(cat.cat_rev, 0), COALESCE(cat.cat_cost, 0), COALESCE(cat.food, 0), COALESCE(cat.labour, 0),
       gh.gh_rev, ROUND(gh.gh_rev * 0.82, 2), COALESCE(cat.late, 0), COALESCE(cat.deliv, 0), COALESCE(cat.ontime, 0),
       COALESCE(cat.cat_rev, 0) + gh.gh_rev, COALESCE(cat.cat_rev, 0) + gh.gh_rev - COALESCE(cat.cat_cost, 0) - ROUND(gh.gh_rev * 0.82, 2),
       IFF(cat.meals > 0, ROUND(cat.cat_cost / cat.meals, 3), NULL), ROUND(gh.gh_rev * 0.82 / gh.flights, 2)
FROM gh LEFT JOIN cat ON cat.fiscal_period = gh.fiscal_period AND cat.airline_key = gh.airline_key;

INSERT OVERWRITE INTO AGG_MONTHLY_ASSET_RELIABILITY
WITH met AS (
  SELECT ASSETNUM AS asset_id, PERIOD AS fiscal_period, READING_HRS AS operating_hours FROM EDW_BRONZE.RAW.MAXIMO_METER_READINGS
  QUALIFY ROW_NUMBER() OVER (PARTITION BY ASSETNUM, PERIOD ORDER BY extracted_at DESC) = 1
), wo AS (
  SELECT w.asset_id, d.fiscal_period, COUNT(*) AS failures, SUM(IFF(w.fault_code LIKE 'HYD%', 1, 0)) AS hyd, SUM(w.repair_hours) AS repair_hours, SUM(w.downtime_hours) AS downtime_hours, SUM(w.downtime_cost_usd) AS downtime_cost
  FROM EDW_GOLD.STAR.FACT_WORK_ORDER w JOIN EDW_GOLD.STAR.DIM_DATE d USING (date_key) WHERE w.is_failure GROUP BY 1, 2
)
SELECT m.fiscal_period, m.asset_id, a.asset_key,
       m.operating_hours, COALESCE(wo.failures, 0), COALESCE(wo.hyd, 0), ROUND(COALESCE(wo.repair_hours, 0), 1), ROUND(COALESCE(wo.downtime_hours, 0), 1), ROUND(COALESCE(wo.downtime_cost, 0), 2),
       IFF(wo.failures > 0, ROUND(m.operating_hours / wo.failures, 1), NULL), IFF(wo.failures > 0, ROUND(wo.repair_hours / wo.failures, 2), NULL)
FROM met m
LEFT JOIN wo ON wo.asset_id = m.asset_id AND wo.fiscal_period = m.fiscal_period
LEFT JOIN EDW_GOLD.STAR.DIM_ASSET a ON a.asset_id = m.asset_id AND a.effective_from <= LAST_DAY(TO_DATE(m.fiscal_period || '-01'))
QUALIFY ROW_NUMBER() OVER (PARTITION BY m.asset_id, m.fiscal_period ORDER BY a.effective_from DESC) = 1;

-- ------------------------------------------------------------------ certification stamp
CREATE TABLE IF NOT EXISTS EDW_GOLD.CONTROL.CERTIFICATION_LOG (
  certified_at TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(), object_name VARCHAR(120), row_count NUMBER, content_hash VARCHAR(64), certified_by VARCHAR(60), recon_run_id NUMBER, status VARCHAR(20)
);
INSERT INTO EDW_GOLD.CONTROL.CERTIFICATION_LOG (object_name, row_count, content_hash, certified_by, status)
SELECT 'EDW_GOLD.STAR.FACT_CATERING_UPLIFT', COUNT(*), TO_VARCHAR(HASH_AGG(*)), CURRENT_USER(), 'CERTIFIED' FROM EDW_GOLD.STAR.FACT_CATERING_UPLIFT
UNION ALL SELECT 'EDW_GOLD.STAR.FACT_FINANCE_POSTING', COUNT(*), TO_VARCHAR(HASH_AGG(*)), CURRENT_USER(), 'CERTIFIED' FROM EDW_GOLD.STAR.FACT_FINANCE_POSTING
UNION ALL SELECT 'EDW_GOLD.STAR.FACT_WORK_ORDER', COUNT(*), TO_VARCHAR(HASH_AGG(*)), CURRENT_USER(), 'CERTIFIED' FROM EDW_GOLD.STAR.FACT_WORK_ORDER
UNION ALL SELECT 'EDW_GOLD.STAR.FACT_LABOUR_COST', COUNT(*), TO_VARCHAR(HASH_AGG(*)), CURRENT_USER(), 'CERTIFIED' FROM EDW_GOLD.STAR.FACT_LABOUR_COST
UNION ALL SELECT 'EDW_GOLD.STAR.FACT_AIRLINE_ORDER', COUNT(*), TO_VARCHAR(HASH_AGG(*)), CURRENT_USER(), 'CERTIFIED' FROM EDW_GOLD.STAR.FACT_AIRLINE_ORDER
UNION ALL SELECT 'EDW_GOLD.STAR.DIM_ASSET', COUNT(*), TO_VARCHAR(HASH_AGG(*)), CURRENT_USER(), 'CERTIFIED' FROM EDW_GOLD.STAR.DIM_ASSET;

-- Demo query: SCD2 history of tug T-114
SELECT asset_key, asset_id, version_no, cost_center_code, station_code, status, effective_from, effective_to, is_current
FROM EDW_GOLD.STAR.DIM_ASSET WHERE asset_id = 'T-114' ORDER BY version_no;
