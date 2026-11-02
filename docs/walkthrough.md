# Walkthrough

The platform shown step by step: what to run (role `ROLE_ELT_ADMIN`, warehouse `WH_ELT`) and what you should see. Load the data first (README, Run it).

## 1. Ingest (Bronze)
Run the COPY block of `sql/02_bronze_load.sql` (28 strict loads), then the inventory query at the end of the file.
```sql
SELECT 'CMS_UPLIFT_FLIGHT_CLASS' AS object, COUNT(*) AS rows_landed, MIN(extracted_at), MAX(extracted_at), COUNT(DISTINCT batch_id) FROM EDW_BRONZE.RAW.CMS_UPLIFT_FLIGHT_CLASS
UNION ALL SELECT 'SAP_GL_ACTUALS_MONTHLY', COUNT(*), MIN(extracted_at), MAX(extracted_at), COUNT(DISTINCT batch_id) FROM EDW_BRONZE.RAW.SAP_GL_ACTUALS_MONTHLY
UNION ALL SELECT 'SF_EMPLOYEE_MASTER', COUNT(*), MIN(extracted_at), MAX(extracted_at), COUNT(DISTINCT batch_id) FROM EDW_BRONZE.RAW.SF_EMPLOYEE_MASTER;
```
*See:* 28 source objects landed with `src_system / extracted_at / batch_id / row_hash` on every row; 21 monthly batches for SAP; raw defects still present (lower-case `ek`, duplicate `UPLIFT_ID`s):
```sql
SELECT CARRIER, COUNT(*) FROM EDW_BRONZE.RAW.CMS_UPLIFT_FLIGHT_CLASS GROUP BY 1 ORDER BY 1;          -- 'ek', 'fz', 'gf' appear next to 'EK', 'FZ', 'GC'
SELECT UPLIFT_ID, COUNT(*) FROM EDW_BRONZE.RAW.CMS_UPLIFT_FLIGHT_CLASS GROUP BY 1 HAVING COUNT(*) > 1; -- 26 duplicates
```

## 2. Orchestrate the daily drop and quarantine the bad file
Run the "Daily contractor drop" section of `02` statement by statement.
```sql
-- A1: validate without loading
-- (validated against the 14-column file contract; VALIDATION_MODE does not accept a column list)
COPY INTO EDW_BRONZE.LANDING.CONTRACTOR_FEED_CONTRACT
FROM @EDW_BRONZE.LANDING.STG_SOURCE_DROP/bad_files/contractor_feed_2026-09-28_malformed.csv
FILE_FORMAT = (FORMAT_NAME = 'EDW_BRONZE.LANDING.FF_CSV_STD') VALIDATION_MODE = 'RETURN_ERRORS';
```
*See:* "Number of columns in file (12) does not match that of the corresponding table (14)" - zero rows written. Then A2 (log + `COPY FILES` to the quarantine stage), A3 (lenient landing), and finally step B loads the corrected file: 370 rows, stamped `CONTRACTOR_20260928_002`.
```sql
SELECT * FROM EDW_BRONZE.LANDING.FILE_LOAD_LOG ORDER BY loaded_at DESC;   -- QUARANTINED row then LOADED row
```
In production the same sequence is a Snowflake Task / Airflow DAG triggered by the stage directory event; here it is run by hand.

## 3. Conform (Silver): dedup, harmonise, MDM, DQ
Run `sql/03_silver_transform.sql` to the end. Then show:
```sql
-- entity harmonisation: four systems, four spellings, one code
SELECT * FROM EDW_SILVER.CONFORMED.ENTITY_CODE_MAP ORDER BY entity_code, src_system;
-- dedup effect
SELECT (SELECT COUNT(*) FROM EDW_BRONZE.RAW.CMS_UPLIFT_FLIGHT_CLASS) AS bronze_rows, (SELECT COUNT(*) FROM EDW_SILVER.CONFORMED.CMS_UPLIFT_LIVE_CLEAN) AS silver_rows;  -- 6730 -> 6704
-- MDM: the 17 duplicates and their golden record
SELECT x.source_vendor_id, x.source_vendor_name, x.created_by, x.match_rule, x.confidence, x.golden_vendor_id, v.golden_vendor_name
FROM EDW_SILVER.MDM.VENDOR_XREF x JOIN EDW_SILVER.MDM.VENDOR_GOLDEN v USING (golden_vendor_id) WHERE x.record_role = 'DUPLICATE' ORDER BY 6;
-- DQ quarantine: which rows of the bad file failed which rule
SELECT file_row_number, failed_rules, row_payload:INVOICE_DATE::STRING AS invoice_date, row_payload:REG_HOURS::STRING AS reg_hours,
       row_payload:OT_HOURS::STRING AS ot_hours, row_payload:AMOUNT_USD::STRING AS amount, row_payload:RATE_USD::STRING AS rate, row_payload:VENDOR_ID::STRING AS vendor_id
FROM EDW_SILVER.DQ.DQ_QUARANTINE WHERE failed_rules <> 'DQ-STRUCT' ORDER BY 1;
SELECT r.rule_id, d.rule_name, r.target_object, r.rows_checked, r.rows_failed, r.fail_pct, r.status FROM EDW_SILVER.DQ.DQ_RESULTS r JOIN EDW_SILVER.DQ.DQ_RULES d USING (rule_id) ORDER BY r.run_ts, r.rule_id;
```
*See:* 97 -> 80 vendors with match rule and confidence; the quarantine lists every row with its failed rule ids - three bad dates (DQ-001), two negative-hours rows (DQ-002), one 612-hour row (DQ-003), the `TBC` amount (DQ-004), the `USD 2.75` rate (DQ-005), the blank contractor id (DQ-006), vendor `V1OO212` (DQ-007) and the duplicated invoice lines (DQ-008), all also flagged DQ-STRUCT for the 12-of-14 column contract; the DQ scorecard shows PASS for the corrected file.

## 4. Model (Gold star schema, SCD2, aggregates)
Run `sql/04_gold_model.sql` (loads section). Show:
```sql
SELECT asset_key, asset_id, version_no, cost_center_code, station_code, status, effective_from, effective_to, is_current
FROM EDW_GOLD.STAR.DIM_ASSET WHERE asset_id = 'T-114' ORDER BY version_no;                  -- 3 versions
SELECT fiscal_period, failures, hydraulic_faults, downtime_hours, downtime_cost_usd, mtbf_hours, mttr_hours
FROM EDW_GOLD.AGG.AGG_MONTHLY_ASSET_RELIABILITY WHERE asset_id = 'T-114' AND fiscal_period >= '2026-01' ORDER BY 1;
SELECT * FROM EDW_GOLD.CONTROL.CERTIFICATION_LOG ORDER BY certified_at DESC;              -- status CERTIFIED, content hash per fact
```
*See:* T-114 moves cost centre in May-2026, goes on the hydraulic watch list 20-Aug-2026, and the monthly reliability line shows faults 1,1,1,2,2,3,5 with downtime cost climbing to USD 4,658 in September. Work orders point at the asset *version* in force on the day (SCD2 lookup).

## 5. Reconcile
Run `sql/05_reconciliation.sql`, then:
```sql
SELECT status, COUNT(*) FROM EDW_GOLD.CONTROL.RECON_RESULTS WHERE run_id = (SELECT MAX(run_id) FROM EDW_GOLD.CONTROL.RECON_RESULTS) GROUP BY 1;
SELECT * FROM EDW_GOLD.CONTROL.V_RECON_LATEST;
```
*See:* GL balance Bronze = Gold for every entity x month (84 rows PASS, variance 0.00), budget totals PASS, meals uplifted by period PASS with the note "26 duplicates removed in Silver", row lineage 6,730 -> 6,704, downtime hours PASS, contractor OT hours per period PASS (incl. Sep-2026 from the corrected file), row-hash set equality PASS, aggregate hash Silver = Gold PASS; INFO rows for vendor 97 -> 80 and quarantined 373 / accepted 370.

## 6. Certify and consume
Run `sql/06_security_rls.sql` and `sql/07_semantic_measures.sql`. Then switch roles live (the row counts change with no report logic):
```sql
USE ROLE ROLE_GROUP_EXEC;  SELECT e.entity_code, COUNT(*) FROM EDW_GOLD.STAR.FACT_FINANCE_POSTING f JOIN EDW_GOLD.STAR.DIM_ENTITY e USING (entity_key) GROUP BY 1;  -- 4 entities
USE ROLE ROLE_FIN_ASC;     SELECT e.entity_code, COUNT(*) FROM EDW_GOLD.STAR.FACT_FINANCE_POSTING f JOIN EDW_GOLD.STAR.DIM_ENTITY e USING (entity_key) GROUP BY 1;  -- ASC only
USE ROLE ROLE_HR_BP;       SELECT employee_id, full_name, national_id, monthly_salary_usd FROM EDW_GOLD.STAR.DIM_EMPLOYEE LIMIT 5;   -- clear
USE ROLE ROLE_GROUP_EXEC;  SELECT employee_id, full_name, national_id, monthly_salary_usd FROM EDW_GOLD.STAR.DIM_EMPLOYEE LIMIT 5;   -- ***MASKED*** / ******789 / NULL
USE ROLE ROLE_INTERNAL_AUDIT; SELECT employee_id, full_name, national_id, monthly_salary_usd FROM EDW_GOLD.STAR.DIM_EMPLOYEE LIMIT 5; -- H:hash / banded to 100
```
Then the certified measure and the "why" question (same SQL that Cortex Analyst's verified query runs):
```sql
USE ROLE ROLE_GROUP_EXEC;
SELECT * FROM EDW_GOLD.CONTROL.MEASURE_CATALOG WHERE measure_id IN ('M-002', 'M-006', 'M-009', 'M-021', 'M-027');
SELECT fiscal_quarter, airline_name, demo_alias, ROUND(SUM(total_cost_usd)/SUM(meals_uplifted), 3) AS cost_per_meal, ROUND(SUM(food_cost_usd)/SUM(meals_uplifted), 3) AS food_per_meal,
       ROUND(SUM(labour_cost_usd)/SUM(meals_uplifted), 3) AS labour_per_meal, ROUND(100*SUM(meals_wasted)/SUM(meals_uplifted), 2) AS wastage_pct,
       SUM(late_downlift_confirmations) AS late_downlifts, MAX(spec_version) AS menu_spec_version
FROM EDW_GOLD.SEMANTIC.V_CATERING_UPLIFT WHERE fiscal_quarter IN ('FY26 Q2', 'FY26 Q3') GROUP BY 1, 2, 3 ORDER BY 2, 1;
SELECT * FROM EDW_GOLD.SEMANTIC.V_KPI_MONTHLY_GROUP ORDER BY fiscal_period DESC LIMIT 6;
```
*See:* Emirates, flydubai and Charter are the only contracts whose cost per meal moved (+12-13%), with the decomposition on screen: menu spec version 3, food per meal up ~USD 0.3-0.7, labour per meal up, wastage ~x1.8, late downlifts x4. Then open Power BI (Group Scorecard, Catering Cost per Meal, GSE Reliability, People & Contractors pages) and ask Cortex Analyst: *"Which airline contracts had the highest cost per meal last quarter, and why?"*, *"Is tug T-114 getting worse?"*, *"How much did contractor overtime at ASCWF change in September?"* - answers come from the same Gold views, under the same policies.

## Modelling notes

- **Size trade-offs (pack about 16 MB).** Bronze CMS is flight x class only for Sep-2026 (live window); earlier months ship as a daily backfill extract (`CMS_UPLIFT_DAILY_HISTORY`). SF time entries ship for 2026 only, so `FACT_LABOUR_COST` has permanents for 2026 and contractors for the full period (the expected-results CSV also has 2025 permanents). SITA messages cover 16-30 Sep 2026; earlier flight history comes from the AODB daily movements in Bronze, and `04` refreshes the SITA days. The recon checks are scoped to periods present in Bronze.
- **Catering labour in the fact is an allocated standard cost** (per-meal rate x produced meals, night premium), not the SuccessFactors payroll; the GL carries actual payroll. Both are stated in the measure catalog (M-008 vs M-030).
- **Handling cost per airline** in `AGG_MONTHLY_AIRLINE_PNL` uses a certified 82% cost ratio of handling revenue; `cost_per_flight_serviced` at entity level uses actual Ground Handling GL cost.
- **Intercompany**: ASCWF bills ASC for contractors (GL 400500 revenue / 510700 cost). Group revenue/EBITDA exclude it via `DIM_GL_ACCOUNT.is_intercompany`; entity P&Ls include it.
- `row_hash` is a 12-hex-character MD5 prefix (size), fine for the lineage demo; use full MD5/SHA2 in production.
