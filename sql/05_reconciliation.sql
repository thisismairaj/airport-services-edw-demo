-- =============================================================================
-- 05_reconciliation.sql  |  Source-to-target control totals -> EDW_GOLD.CONTROL.RECON_RESULTS
-- Each check writes one row per grain with source value, target value, variance and PASS/FAIL.
-- Run after 04. The final SELECT is what is shown to the committee.
-- =============================================================================
USE ROLE ROLE_ELT_ADMIN;
USE WAREHOUSE WH_ELT;
USE SCHEMA EDW_GOLD.CONTROL;

CREATE TABLE IF NOT EXISTS RECON_RESULTS (
  recon_id        NUMBER AUTOINCREMENT,
  run_id          NUMBER,
  run_ts          TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
  check_name      VARCHAR(80),
  check_type      VARCHAR(20),          -- BALANCE | COUNT | HASH | MEASURE
  src_system      VARCHAR(20),
  source_object   VARCHAR(120),
  target_object   VARCHAR(120),
  grain           VARCHAR(120),         -- e.g. entity=ASC, period=2026-09
  source_value    NUMBER(38,3),
  target_value    NUMBER(38,3),
  variance        NUMBER(38,3),
  variance_pct    NUMBER(9,4),
  tolerance_pct   NUMBER(9,4),
  status          VARCHAR(10),          -- PASS | FAIL | INFO
  note            VARCHAR(400)
);

SET run_id = (SELECT COALESCE(MAX(run_id), 0) + 1 FROM RECON_RESULTS);

-- ------------------------------------------------------------------ 1. GL balance: Bronze SAP (DMBTR) vs Gold FACT_FINANCE_POSTING, per entity x period
INSERT INTO RECON_RESULTS (run_id, check_name, check_type, src_system, source_object, target_object, grain, source_value, target_value, variance, variance_pct, tolerance_pct, status, note)
WITH src AS (
  SELECT m.entity_code, a.GJAHR || '-' || LPAD(a.MONAT, 2, '0') AS fiscal_period, SUM(a.DMBTR) AS v
  FROM EDW_BRONZE.RAW.SAP_GL_ACTUALS_MONTHLY a JOIN EDW_SILVER.CONFORMED.ENTITY_CODE_MAP m ON m.src_system = 'SAP' AND m.src_code = a.BUKRS
  GROUP BY 1, 2
), tgt AS (
  SELECT e.entity_code, f.fiscal_period, SUM(f.amount_usd) AS v
  FROM EDW_GOLD.STAR.FACT_FINANCE_POSTING f JOIN EDW_GOLD.STAR.DIM_ENTITY e USING (entity_key) GROUP BY 1, 2
)
SELECT $run_id, 'GL balance by entity/period', 'BALANCE', 'SAP', 'EDW_BRONZE.RAW.SAP_GL_ACTUALS_MONTHLY', 'EDW_GOLD.STAR.FACT_FINANCE_POSTING',
       'entity=' || COALESCE(s.entity_code, t.entity_code) || ', period=' || COALESCE(s.fiscal_period, t.fiscal_period),
       s.v, t.v, COALESCE(t.v, 0) - COALESCE(s.v, 0), IFF(s.v = 0, NULL, ROUND(100 * (COALESCE(t.v, 0) - s.v) / ABS(s.v), 4)), 0.0001,
       IFF(ABS(COALESCE(t.v, 0) - COALESCE(s.v, 0)) < 0.01, 'PASS', 'FAIL'), 'Group currency USD; ASCSA document currency SAR converted upstream in SAP (DMBTR)'
FROM src s FULL OUTER JOIN tgt t ON t.entity_code = s.entity_code AND t.fiscal_period = s.fiscal_period;

-- ------------------------------------------------------------------ 2. Budget totals: Bronze CO plan vs Gold budget_usd, per entity x year
INSERT INTO RECON_RESULTS (run_id, check_name, check_type, src_system, source_object, target_object, grain, source_value, target_value, variance, variance_pct, tolerance_pct, status)
WITH src AS (SELECT m.entity_code, b.GJAHR, SUM(b.PLAN_AMOUNT_USD) v FROM EDW_BRONZE.RAW.SAP_CO_BUDGET_MONTHLY b JOIN EDW_SILVER.CONFORMED.ENTITY_CODE_MAP m ON m.src_system = 'SAP' AND m.src_code = b.BUKRS GROUP BY 1, 2),
     tgt AS (SELECT e.entity_code, f.fiscal_year::VARCHAR AS GJAHR, SUM(f.budget_usd) v FROM EDW_GOLD.STAR.FACT_FINANCE_POSTING f JOIN EDW_GOLD.STAR.DIM_ENTITY e USING (entity_key) GROUP BY 1, 2)
SELECT $run_id, 'Budget total by entity/year', 'BALANCE', 'SAP', 'EDW_BRONZE.RAW.SAP_CO_BUDGET_MONTHLY', 'EDW_GOLD.STAR.FACT_FINANCE_POSTING',
       'entity=' || s.entity_code || ', year=' || s.GJAHR, s.v, t.v, t.v - s.v, ROUND(100 * (t.v - s.v) / NULLIF(ABS(s.v), 0), 4), 0.0001, IFF(ABS(t.v - s.v) < 0.01, 'PASS', 'FAIL')
FROM src s JOIN tgt t ON t.entity_code = s.entity_code AND t.GJAHR = s.GJAHR;

-- ------------------------------------------------------------------ 3. Meal counts: Bronze CMS (history + de-duplicated live) vs Gold, per period
INSERT INTO RECON_RESULTS (run_id, check_name, check_type, src_system, source_object, target_object, grain, source_value, target_value, variance, variance_pct, tolerance_pct, status, note)
WITH src AS (
  SELECT TO_CHAR(UPLIFT_DATE, 'YYYY-MM') AS p, SUM(MEALS_UPLIFTED) v, 'history' AS part FROM EDW_BRONZE.RAW.CMS_UPLIFT_DAILY_HISTORY GROUP BY 1
  UNION ALL
  SELECT TO_CHAR(FLT_DATE, 'YYYY-MM'), SUM(MEALS_UPLIFTED), 'live (dedup)' FROM (SELECT * FROM EDW_BRONZE.RAW.CMS_UPLIFT_FLIGHT_CLASS QUALIFY ROW_NUMBER() OVER (PARTITION BY UPLIFT_ID ORDER BY extracted_at DESC) = 1) GROUP BY 1
), tgt AS (SELECT d.fiscal_period p, SUM(meals_uplifted) v FROM EDW_GOLD.STAR.FACT_CATERING_UPLIFT f JOIN EDW_GOLD.STAR.DIM_DATE d USING (date_key) GROUP BY 1)
SELECT $run_id, 'Meals uplifted by period', 'MEASURE', 'CMS', 'EDW_BRONZE.RAW.CMS_UPLIFT_* (' || s.part || ')', 'EDW_GOLD.STAR.FACT_CATERING_UPLIFT', 'period=' || s.p,
       s.v, t.v, t.v - s.v, ROUND(100 * (t.v - s.v) / NULLIF(s.v, 0), 4), 0, IFF(t.v = s.v, 'PASS', 'FAIL'),
       IFF(s.part LIKE 'live%', 'Live feed carried 26 exact duplicate rows; removed in Silver (QUALIFY on UPLIFT_ID)', NULL)
FROM src s JOIN tgt t ON t.p = s.p;

-- Same for catering revenue (billing) and total cost
INSERT INTO RECON_RESULTS (run_id, check_name, check_type, src_system, source_object, target_object, grain, source_value, target_value, variance, variance_pct, tolerance_pct, status)
WITH src AS (
  SELECT 'all periods' g, SUM(BILL_AMOUNT) rev, SUM(FOOD_COST + LABOUR_COST + OVERHEAD_COST) cost FROM (
    SELECT BILL_AMOUNT, FOOD_COST, LABOUR_COST, OVERHEAD_COST FROM EDW_BRONZE.RAW.CMS_UPLIFT_DAILY_HISTORY
    UNION ALL SELECT BILL_AMOUNT, FOOD_COST, LABOUR_COST, OVERHEAD_COST FROM (SELECT * FROM EDW_BRONZE.RAW.CMS_UPLIFT_FLIGHT_CLASS QUALIFY ROW_NUMBER() OVER (PARTITION BY UPLIFT_ID ORDER BY extracted_at DESC) = 1))
), tgt AS (SELECT SUM(revenue_usd) rev, SUM(total_cost_usd) cost FROM EDW_GOLD.STAR.FACT_CATERING_UPLIFT)
SELECT $run_id, 'Catering revenue total', 'BALANCE', 'CMS', 'EDW_BRONZE.RAW.CMS_UPLIFT_*', 'EDW_GOLD.STAR.FACT_CATERING_UPLIFT', s.g, s.rev, t.rev, t.rev - s.rev, ROUND(100 * (t.rev - s.rev) / s.rev, 4), 0.0001, IFF(ABS(t.rev - s.rev) < 0.05, 'PASS', 'FAIL') FROM src s, tgt t
UNION ALL
SELECT $run_id, 'Catering cost total', 'BALANCE', 'CMS', 'EDW_BRONZE.RAW.CMS_UPLIFT_*', 'EDW_GOLD.STAR.FACT_CATERING_UPLIFT', s.g, s.cost, t.cost, t.cost - s.cost, ROUND(100 * (t.cost - s.cost) / s.cost, 4), 0.0001, IFF(ABS(t.cost - s.cost) < 0.05, 'PASS', 'FAIL') FROM src s, tgt t;

-- ------------------------------------------------------------------ 4. Record counts through the layers (raw -> dedup -> silver -> gold)
INSERT INTO RECON_RESULTS (run_id, check_name, check_type, src_system, source_object, target_object, grain, source_value, target_value, variance, variance_pct, tolerance_pct, status, note)
SELECT $run_id, 'CMS live feed row lineage', 'COUNT', 'CMS', 'EDW_BRONZE.RAW.CMS_UPLIFT_FLIGHT_CLASS', 'EDW_SILVER.CONFORMED.CMS_UPLIFT_LIVE_CLEAN', 'batch=CMS_202609_001',
       (SELECT COUNT(*) FROM EDW_BRONZE.RAW.CMS_UPLIFT_FLIGHT_CLASS), (SELECT COUNT(*) FROM EDW_SILVER.CONFORMED.CMS_UPLIFT_LIVE_CLEAN),
       (SELECT COUNT(*) FROM EDW_SILVER.CONFORMED.CMS_UPLIFT_LIVE_CLEAN) - (SELECT COUNT(*) FROM EDW_BRONZE.RAW.CMS_UPLIFT_FLIGHT_CLASS), NULL, NULL,
       IFF((SELECT COUNT(*) FROM EDW_BRONZE.RAW.CMS_UPLIFT_FLIGHT_CLASS) - (SELECT COUNT(*) FROM EDW_SILVER.CONFORMED.CMS_UPLIFT_LIVE_CLEAN) = (SELECT COUNT(*) - COUNT(DISTINCT UPLIFT_ID) FROM EDW_BRONZE.RAW.CMS_UPLIFT_FLIGHT_CLASS), 'PASS', 'FAIL'),
       'Variance must equal the number of exact duplicates in the raw file (expected -26)'
UNION ALL
SELECT $run_id, 'SF employee master row lineage', 'COUNT', 'SF', 'EDW_BRONZE.RAW.SF_EMPLOYEE_MASTER', 'EDW_SILVER.CONFORMED.SF_EMPLOYEE_CONFORMED', 'batch=SF_202609_001',
       (SELECT COUNT(*) FROM EDW_BRONZE.RAW.SF_EMPLOYEE_MASTER), (SELECT COUNT(*) FROM EDW_SILVER.CONFORMED.SF_EMPLOYEE_CONFORMED),
       (SELECT COUNT(*) FROM EDW_SILVER.CONFORMED.SF_EMPLOYEE_CONFORMED) - (SELECT COUNT(*) FROM EDW_BRONZE.RAW.SF_EMPLOYEE_MASTER), NULL, NULL,
       IFF((SELECT COUNT(DISTINCT PERSON_ID_EXTERNAL) FROM EDW_BRONZE.RAW.SF_EMPLOYEE_MASTER) = (SELECT COUNT(*) FROM EDW_SILVER.CONFORMED.SF_EMPLOYEE_CONFORMED), 'PASS', 'FAIL'),
       'Expected -8 (duplicate person rows in the SF extract)'
UNION ALL
SELECT $run_id, 'Maximo work orders', 'COUNT', 'MAXIMO', 'EDW_BRONZE.RAW.MAXIMO_WORK_ORDERS', 'EDW_GOLD.STAR.FACT_WORK_ORDER', 'all',
       (SELECT COUNT(DISTINCT WONUM) FROM EDW_BRONZE.RAW.MAXIMO_WORK_ORDERS), (SELECT COUNT(*) FROM EDW_GOLD.STAR.FACT_WORK_ORDER),
       (SELECT COUNT(*) FROM EDW_GOLD.STAR.FACT_WORK_ORDER) - (SELECT COUNT(DISTINCT WONUM) FROM EDW_BRONZE.RAW.MAXIMO_WORK_ORDERS), NULL, 0,
       IFF((SELECT COUNT(DISTINCT WONUM) FROM EDW_BRONZE.RAW.MAXIMO_WORK_ORDERS) = (SELECT COUNT(*) FROM EDW_GOLD.STAR.FACT_WORK_ORDER), 'PASS', 'FAIL'), NULL
UNION ALL
SELECT $run_id, 'Vendor master -> golden records', 'COUNT', 'SAP', 'EDW_BRONZE.RAW.SAP_VENDOR_MASTER', 'EDW_GOLD.STAR.DIM_VENDOR', 'all',
       (SELECT COUNT(*) FROM EDW_BRONZE.RAW.SAP_VENDOR_MASTER), (SELECT COUNT(*) FROM EDW_GOLD.STAR.DIM_VENDOR),
       (SELECT COUNT(*) FROM EDW_GOLD.STAR.DIM_VENDOR) - (SELECT COUNT(*) FROM EDW_BRONZE.RAW.SAP_VENDOR_MASTER), NULL, NULL, 'INFO', '97 source records -> 80 golden (17 duplicates mastered)'
UNION ALL
SELECT $run_id, 'Contractor daily drop (Sep-2026)', 'COUNT', 'CONTRACTOR', 'STG_SOURCE_DROP/bad_files/*2026-09-28*', 'EDW_BRONZE.RAW.CONTRACTOR_FEED_DAILY', 'batch=CONTRACTOR_20260928',
       (SELECT COUNT(*) FROM EDW_SILVER.DQ.DQ_QUARANTINE WHERE batch_id = 'CONTRACTOR_20260928_001'), (SELECT COUNT(*) FROM EDW_BRONZE.RAW.CONTRACTOR_FEED_DAILY WHERE batch_id = 'CONTRACTOR_20260928_002'),
       NULL, NULL, NULL, 'INFO', 'source_value = rows quarantined from the malformed file; target_value = rows accepted from the corrected file';

-- ------------------------------------------------------------------ 5. Work-order downtime hours & contractor hours (measure totals)
INSERT INTO RECON_RESULTS (run_id, check_name, check_type, src_system, source_object, target_object, grain, source_value, target_value, variance, variance_pct, tolerance_pct, status)
SELECT $run_id, 'Downtime hours (Maximo vs Gold)', 'MEASURE', 'MAXIMO', 'EDW_BRONZE.RAW.MAXIMO_WORK_ORDERS', 'EDW_GOLD.STAR.FACT_WORK_ORDER', 'all',
       s.v, t.v, t.v - s.v, ROUND(100 * (t.v - s.v) / s.v, 4), 0.0001, IFF(ABS(t.v - s.v) < 0.05, 'PASS', 'FAIL')
FROM (SELECT SUM(DOWNTIME_HRS) v FROM (SELECT * FROM EDW_BRONZE.RAW.MAXIMO_WORK_ORDERS QUALIFY ROW_NUMBER() OVER (PARTITION BY WONUM ORDER BY extracted_at DESC) = 1)) s,
     (SELECT SUM(downtime_hours) v FROM EDW_GOLD.STAR.FACT_WORK_ORDER) t
UNION ALL
SELECT $run_id, 'Contractor OT hours by period', 'MEASURE', 'CONTRACTOR', 'EDW_BRONZE.RAW.CONTRACTOR_FEED_*', 'EDW_GOLD.STAR.FACT_LABOUR_COST', 'period=' || s.p,
       s.v, t.v, t.v - s.v, ROUND(100 * (t.v - s.v) / NULLIF(s.v, 0), 4), 0, IFF(t.v = s.v, 'PASS', 'FAIL')
FROM (SELECT PERIOD p, SUM(OT_HOURS) v FROM (SELECT PERIOD, OT_HOURS FROM EDW_BRONZE.RAW.CONTRACTOR_FEED_INVOICE_LINES UNION ALL SELECT PERIOD, OT_HOURS FROM EDW_BRONZE.RAW.CONTRACTOR_FEED_DAILY) GROUP BY 1) s
JOIN (SELECT fiscal_period p, SUM(overtime_hours) v FROM EDW_GOLD.STAR.FACT_LABOUR_COST WHERE employment_type = 'Contractor' GROUP BY 1) t ON t.p = s.p;

-- ------------------------------------------------------------------ 6. Hash checks: row-hash set equality Bronze->Silver, aggregate hash Silver->Gold
INSERT INTO RECON_RESULTS (run_id, check_name, check_type, src_system, source_object, target_object, grain, source_value, target_value, variance, variance_pct, tolerance_pct, status, note)
SELECT $run_id, 'Row-hash set: CMS live feed', 'HASH', 'CMS', 'EDW_BRONZE.RAW.CMS_UPLIFT_FLIGHT_CLASS', 'EDW_SILVER.CONFORMED.CMS_UPLIFT_LIVE_CLEAN', 'distinct row_hash',
       (SELECT COUNT(DISTINCT row_hash) FROM EDW_BRONZE.RAW.CMS_UPLIFT_FLIGHT_CLASS), (SELECT COUNT(DISTINCT row_hash) FROM EDW_SILVER.CONFORMED.CMS_UPLIFT_LIVE_CLEAN),
       (SELECT COUNT(DISTINCT row_hash) FROM EDW_SILVER.CONFORMED.CMS_UPLIFT_LIVE_CLEAN) - (SELECT COUNT(DISTINCT row_hash) FROM EDW_BRONZE.RAW.CMS_UPLIFT_FLIGHT_CLASS), NULL, 0,
       IFF((SELECT COUNT(*) FROM (SELECT row_hash FROM EDW_BRONZE.RAW.CMS_UPLIFT_FLIGHT_CLASS EXCEPT SELECT row_hash FROM EDW_SILVER.CONFORMED.CMS_UPLIFT_LIVE_CLEAN)) = 0, 'PASS', 'FAIL'),
       'Every distinct source row hash survives into Silver (duplicates collapse, nothing is lost)'
UNION ALL
SELECT $run_id, 'Aggregate hash: Silver daily uplift vs Gold fact', 'HASH', 'CMS', 'EDW_SILVER.CONFORMED.CMS_UPLIFT_DAILY', 'EDW_GOLD.STAR.FACT_CATERING_UPLIFT', 'HASH_AGG(date, carrier, class, meals, cost)',
       (SELECT HASH_AGG(uplift_date::DATE, carrier::VARCHAR, route_group::VARCHAR, meal_class::VARCHAR, meals_uplifted::NUMBER(10,0), ROUND(food_cost + labour_cost + overhead_cost, 2)::NUMBER(16,2)) FROM EDW_SILVER.CONFORMED.CMS_UPLIFT_DAILY),
       (SELECT HASH_AGG(d.calendar_date::DATE, a.airline_code::VARCHAR, f.route_group::VARCHAR, f.meal_class::VARCHAR, f.meals_uplifted::NUMBER(10,0), f.total_cost_usd::NUMBER(16,2)) FROM EDW_GOLD.STAR.FACT_CATERING_UPLIFT f JOIN EDW_GOLD.STAR.DIM_DATE d USING (date_key) JOIN EDW_GOLD.STAR.DIM_AIRLINE a USING (airline_key)),
       NULL, NULL, 0,
       IFF((SELECT HASH_AGG(uplift_date::DATE, carrier::VARCHAR, route_group::VARCHAR, meal_class::VARCHAR, meals_uplifted::NUMBER(10,0), ROUND(food_cost + labour_cost + overhead_cost, 2)::NUMBER(16,2)) FROM EDW_SILVER.CONFORMED.CMS_UPLIFT_DAILY)
         = (SELECT HASH_AGG(d.calendar_date::DATE, a.airline_code::VARCHAR, f.route_group::VARCHAR, f.meal_class::VARCHAR, f.meals_uplifted::NUMBER(10,0), f.total_cost_usd::NUMBER(16,2)) FROM EDW_GOLD.STAR.FACT_CATERING_UPLIFT f JOIN EDW_GOLD.STAR.DIM_DATE d USING (date_key) JOIN EDW_GOLD.STAR.DIM_AIRLINE a USING (airline_key)), 'PASS', 'FAIL'),
       'Order-independent aggregate hash over the business key + measures';

-- ------------------------------------------------------------------ 7. Certification gate: stamp Gold objects only if every non-INFO check passed
UPDATE EDW_GOLD.CONTROL.CERTIFICATION_LOG SET recon_run_id = $run_id, status = IFF((SELECT COUNT(*) FROM RECON_RESULTS WHERE run_id = $run_id AND status = 'FAIL') = 0, 'CERTIFIED', 'HOLD')
WHERE recon_run_id IS NULL;

-- ------------------------------------------------------------------ what the committee sees
CREATE OR REPLACE VIEW V_RECON_LATEST AS
SELECT check_name, check_type, src_system, grain, source_value, target_value, variance, variance_pct, status, note, run_ts
FROM RECON_RESULTS WHERE run_id = (SELECT MAX(run_id) FROM RECON_RESULTS)
ORDER BY CASE status WHEN 'FAIL' THEN 0 WHEN 'INFO' THEN 2 ELSE 1 END, check_name, grain;

SELECT status, COUNT(*) AS checks FROM RECON_RESULTS WHERE run_id = $run_id GROUP BY status ORDER BY status;
SELECT * FROM V_RECON_LATEST;
