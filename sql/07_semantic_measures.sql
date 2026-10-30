-- =============================================================================
-- 07_semantic_measures.sql  |  Certified semantic layer
--   * Flattened views over the star (one row per fact grain, dimension attributes denormalised)
--   * V_KPI_MONTHLY: every certified KPI computed once, in SQL, so Power BI, Cortex Analyst and
--     Excel all read the same number
--   * MEASURE_CATALOG: the governed definition of each measure (owner, formula, lineage, sensitivity)
-- =============================================================================
USE ROLE ROLE_ELT_ADMIN;
USE WAREHOUSE WH_ELT;
USE SCHEMA EDW_GOLD.SEMANTIC;

-- ------------------------------------------------------------------ flattened views (row-level policies on the base tables carry through)
CREATE OR REPLACE VIEW V_CATERING_UPLIFT AS
SELECT f.catering_uplift_key, d.calendar_date AS flight_date, d.fiscal_year, d.fiscal_quarter, d.fiscal_period, d.month_name, d.is_ramadan, d.is_peak_season,
       e.entity_code, e.entity_name, s.station_code, s.station_name, a.airline_code, a.airline_name, a.demo_alias, a.contract_type, a.contract_margin_pct, a.account_manager,
       f.route_group, f.meal_class, m.meal_class_name, m.menu_spec_code, m.spec_version, m.spec_change_reason,
       f.flights_catered, f.meals_planned, f.meals_uplifted, f.meals_downlifted, f.meals_wasted, f.late_downlift_confirmations, f.deliveries_total, f.deliveries_on_time,
       f.food_cost_usd, f.labour_cost_usd, f.overhead_cost_usd, f.total_cost_usd, f.revenue_usd, f.revenue_usd - f.total_cost_usd AS gross_margin_usd, f.src_batch_id
FROM EDW_GOLD.STAR.FACT_CATERING_UPLIFT f
JOIN EDW_GOLD.STAR.DIM_DATE d USING (date_key)
JOIN EDW_GOLD.STAR.DIM_ENTITY e USING (entity_key)
JOIN EDW_GOLD.STAR.DIM_STATION s USING (station_key)
JOIN EDW_GOLD.STAR.DIM_AIRLINE a USING (airline_key)
LEFT JOIN EDW_GOLD.STAR.DIM_MEAL m USING (meal_key);

CREATE OR REPLACE VIEW V_FINANCE_POSTING AS
SELECT f.finance_posting_key, f.fiscal_period, f.fiscal_year, d.fiscal_quarter, d.calendar_date AS period_end_date, e.entity_code, e.entity_name,
       cc.cost_center_code, cc.cost_center_name, cc.business_unit, cc.station_code, gl.gl_account, gl.gl_description, gl.account_class, gl.kpi_group, gl.statement_line, gl.is_ebitda, gl.is_intercompany,
       a.airline_code, a.airline_name, a.demo_alias,
       f.amount_usd, f.budget_usd, f.variance_usd,
       f.amount_usd * gl.natural_sign AS amount_presentation_usd,          -- revenue positive, cost positive
       f.budget_usd * gl.natural_sign AS budget_presentation_usd,
       -f.amount_usd AS pnl_contribution_usd,                                -- revenue (+) minus cost (-), additive to EBITDA
       f.posting_count, f.src_batch_id
FROM EDW_GOLD.STAR.FACT_FINANCE_POSTING f
JOIN EDW_GOLD.STAR.DIM_DATE d USING (date_key)
JOIN EDW_GOLD.STAR.DIM_ENTITY e USING (entity_key)
JOIN EDW_GOLD.STAR.DIM_COST_CENTER cc USING (cost_center_key)
JOIN EDW_GOLD.STAR.DIM_GL_ACCOUNT gl USING (gl_account_key)
LEFT JOIN EDW_GOLD.STAR.DIM_AIRLINE a USING (airline_key);

CREATE OR REPLACE VIEW V_WORK_ORDER AS
SELECT w.work_order_key, w.wo_id, d.calendar_date AS wo_date, d.fiscal_period, d.fiscal_quarter, e.entity_code, s.station_code, cc.cost_center_code, cc.cost_center_name,
       ast.asset_id, ast.asset_type, ast.asset_class, ast.make, ast.model, ast.status AS asset_status_at_wo, ast.criticality, ast.version_no AS asset_version,
       w.wo_type, w.fault_code, w.fault_description, w.fault_code LIKE 'HYD%' AS is_hydraulic_fault, w.priority, w.reported_ts, w.start_ts, w.finish_ts,
       w.downtime_hours, w.repair_hours, w.labour_hours, w.parts_cost_usd, w.labour_cost_usd, w.downtime_cost_usd, w.parts_cost_usd + w.labour_cost_usd + w.downtime_cost_usd AS total_wo_cost_usd,
       w.is_failure, w.status, w.technician_id
FROM EDW_GOLD.STAR.FACT_WORK_ORDER w
JOIN EDW_GOLD.STAR.DIM_DATE d USING (date_key)
JOIN EDW_GOLD.STAR.DIM_ASSET ast USING (asset_key)
JOIN EDW_GOLD.STAR.DIM_ENTITY e ON e.entity_key = w.entity_key
JOIN EDW_GOLD.STAR.DIM_STATION s ON s.station_key = w.station_key
JOIN EDW_GOLD.STAR.DIM_COST_CENTER cc ON cc.cost_center_key = w.cost_center_key;

CREATE OR REPLACE VIEW V_LABOUR_COST AS
SELECT l.labour_cost_key, l.fiscal_period, d.fiscal_quarter, d.fiscal_year, e.entity_code, e.entity_name, cc.cost_center_code, cc.cost_center_name, cc.business_unit, cc.station_code,
       dc.cost_center_code AS deployed_cost_center_code, dc.cost_center_name AS deployed_cost_center_name, dc.business_unit AS deployed_business_unit,
       l.employment_type, l.shift_pattern, l.headcount, l.regular_hours, l.overtime_hours, l.night_hours, l.leave_hours, l.regular_cost_usd, l.overtime_cost_usd, l.benefits_cost_usd, l.total_cost_usd
FROM EDW_GOLD.STAR.FACT_LABOUR_COST l
JOIN EDW_GOLD.STAR.DIM_DATE d USING (date_key)
JOIN EDW_GOLD.STAR.DIM_ENTITY e USING (entity_key)
JOIN EDW_GOLD.STAR.DIM_COST_CENTER cc ON cc.cost_center_key = l.cost_center_key
JOIN EDW_GOLD.STAR.DIM_COST_CENTER dc ON dc.cost_center_key = l.deployed_cost_center_key;

CREATE OR REPLACE VIEW V_AIRLINE_ORDER AS
SELECT o.airline_order_key, d.calendar_date AS order_date, d.fiscal_period, d.fiscal_quarter, a.airline_code, a.airline_name, a.demo_alias, s.station_code,
       o.orders_submitted, o.orders_amended_after_cutoff, o.special_meal_orders, o.special_meals_unfulfilled, o.sla_events, o.sla_breaches, o.sla_events - o.sla_breaches AS sla_met, o.avg_order_lead_hours
FROM EDW_GOLD.STAR.FACT_AIRLINE_ORDER o
JOIN EDW_GOLD.STAR.DIM_DATE d USING (date_key)
JOIN EDW_GOLD.STAR.DIM_AIRLINE a USING (airline_key)
JOIN EDW_GOLD.STAR.DIM_STATION s USING (station_key);

CREATE OR REPLACE VIEW V_DAILY_FLIGHTS AS
SELECT d.calendar_date AS flight_date, d.fiscal_period, d.fiscal_quarter, e.entity_code, s.station_code, a.airline_code, a.airline_name, a.demo_alias, g.route_group,
       g.flights_handled, g.flights_catered, g.departures_on_time, g.total_delay_min, g.handling_revenue_usd
FROM EDW_GOLD.AGG.AGG_DAILY_FLIGHTS g
JOIN EDW_GOLD.STAR.DIM_DATE d USING (date_key)
JOIN EDW_GOLD.STAR.DIM_ENTITY e USING (entity_key)
JOIN EDW_GOLD.STAR.DIM_STATION s USING (station_key)
JOIN EDW_GOLD.STAR.DIM_AIRLINE a USING (airline_key);

CREATE OR REPLACE VIEW V_ASSET_RELIABILITY_MONTHLY AS
SELECT r.fiscal_period, r.asset_id, ast.asset_type, ast.asset_class, ast.make, ast.model, ast.station_code, ast.cost_center_code, ast.status AS asset_status, ast.criticality,
       r.operating_hours, r.failures, r.hydraulic_faults, r.repair_hours, r.downtime_hours, r.downtime_cost_usd, r.mtbf_hours, r.mttr_hours,
       SUM(r.hydraulic_faults) OVER (PARTITION BY r.asset_id ORDER BY r.fiscal_period ROWS BETWEEN 2 PRECEDING AND CURRENT ROW) AS hydraulic_faults_3m,
       AVG(r.downtime_cost_usd) OVER (PARTITION BY r.asset_id ORDER BY r.fiscal_period ROWS BETWEEN 5 PRECEDING AND 1 PRECEDING) AS downtime_cost_6m_baseline
FROM EDW_GOLD.AGG.AGG_MONTHLY_ASSET_RELIABILITY r
JOIN EDW_GOLD.STAR.DIM_ASSET ast ON ast.asset_key = r.asset_key;

CREATE OR REPLACE VIEW V_AIRLINE_PNL_MONTHLY AS
SELECT p.fiscal_period, a.airline_code, a.airline_name, a.demo_alias, a.contract_type, a.account_manager,
       p.flights_handled, p.meals_uplifted, p.meals_wasted, p.catering_revenue_usd, p.catering_cost_usd, p.catering_food_cost_usd, p.catering_labour_cost_usd, p.handling_revenue_usd, p.handling_cost_usd,
       p.late_downlift_confirmations, p.deliveries_total, p.deliveries_on_time, p.total_revenue_usd, p.contribution_margin_usd, p.cost_per_meal_usd, p.cost_per_flight_usd,
       IFF(p.total_revenue_usd > 0, ROUND(100 * p.contribution_margin_usd / p.total_revenue_usd, 2), NULL) AS contribution_margin_pct
FROM EDW_GOLD.AGG.AGG_MONTHLY_AIRLINE_PNL p JOIN EDW_GOLD.STAR.DIM_AIRLINE a USING (airline_key);

-- ------------------------------------------------------------------ V_KPI_MONTHLY: certified KPIs at month x entity grain (airline-level KPIs in V_AIRLINE_PNL_MONTHLY)
CREATE OR REPLACE VIEW V_KPI_MONTHLY AS
WITH fin AS (
  SELECT fiscal_period, entity_code,
         SUM(IFF(account_class = 'Revenue' AND NOT is_intercompany, -amount_usd, 0))                       AS revenue_usd,
         SUM(IFF(account_class = 'Revenue' AND NOT is_intercompany, -budget_usd, 0))                       AS revenue_budget_usd,
         SUM(IFF(is_ebitda AND NOT is_intercompany, -amount_usd, 0))                                        AS ebitda_usd,
         SUM(IFF(is_ebitda AND NOT is_intercompany, -budget_usd, 0))                                        AS ebitda_budget_usd,
         SUM(IFF(account_class IN ('COGS', 'Opex') AND NOT is_intercompany, amount_usd, 0))                 AS operating_cost_usd,
         SUM(IFF(kpi_group = 'Contractor Cost' AND NOT is_intercompany, amount_usd, 0))                     AS contractor_spend_usd,
         SUM(IFF(kpi_group = 'Contractor Cost' AND NOT is_intercompany, budget_usd, 0))                     AS contractor_budget_usd,
         SUM(IFF(business_unit = 'Ground Handling' AND account_class IN ('COGS', 'Opex') AND NOT is_intercompany, amount_usd, 0)) AS ground_handling_cost_usd,
         SUM(IFF(business_unit = 'Flight Catering' AND account_class IN ('COGS', 'Opex') AND NOT is_intercompany, amount_usd, 0)) AS catering_cost_gl_usd
  FROM V_FINANCE_POSTING GROUP BY 1, 2
), cat AS (
  SELECT fiscal_period, entity_code, SUM(meals_uplifted) AS meals_uplifted, SUM(meals_wasted) AS meals_wasted, SUM(total_cost_usd) AS catering_cost_usd, SUM(revenue_usd) AS catering_revenue_usd,
         SUM(deliveries_on_time) AS deliveries_on_time, SUM(deliveries_total) AS deliveries_total, SUM(late_downlift_confirmations) AS late_downlifts
  FROM V_CATERING_UPLIFT GROUP BY 1, 2
), fl AS (
  SELECT fiscal_period, entity_code, SUM(flights_handled) AS flights_handled, SUM(departures_on_time) AS departures_on_time, SUM(handling_revenue_usd) AS handling_revenue_usd FROM V_DAILY_FLIGHTS GROUP BY 1, 2
), lab AS (
  SELECT fiscal_period, entity_code, SUM(regular_hours) AS regular_hours, SUM(overtime_hours) AS overtime_hours, SUM(IFF(employment_type = 'Contractor', overtime_hours, 0)) AS contractor_ot_hours,
         SUM(total_cost_usd) AS labour_cost_usd, SUM(headcount) AS headcount
  FROM V_LABOUR_COST GROUP BY 1, 2
), wo AS (
  SELECT fiscal_period, entity_code, SUM(downtime_cost_usd) AS asset_downtime_cost_usd, SUM(downtime_hours) AS asset_downtime_hours, SUM(IFF(is_failure, 1, 0)) AS failures, SUM(IFF(is_failure, repair_hours, 0)) AS repair_hours
  FROM V_WORK_ORDER GROUP BY 1, 2
), met AS (
  SELECT r.fiscal_period, ast.entity_code, SUM(r.operating_hours) AS operating_hours FROM EDW_GOLD.AGG.AGG_MONTHLY_ASSET_RELIABILITY r JOIN EDW_GOLD.STAR.DIM_ASSET ast ON ast.asset_key = r.asset_key GROUP BY 1, 2
), sla AS (
  SELECT fiscal_period, 'ASC' AS entity_code, SUM(sla_events) AS sla_events, SUM(sla_breaches) AS sla_breaches FROM V_AIRLINE_ORDER GROUP BY 1
)
SELECT f.fiscal_period, f.entity_code,
       f.revenue_usd, f.revenue_budget_usd, f.ebitda_usd, f.ebitda_budget_usd, f.operating_cost_usd,
       IFF(f.revenue_usd <> 0, ROUND(100 * f.ebitda_usd / f.revenue_usd, 2), NULL)                                   AS ebitda_margin_pct,
       c.meals_uplifted, c.meals_wasted, c.catering_cost_usd, c.catering_revenue_usd,
       IFF(c.meals_uplifted > 0, ROUND(c.catering_cost_usd / c.meals_uplifted, 3), NULL)                             AS cost_per_meal_usd,
       IFF(c.meals_uplifted > 0, ROUND(100 * c.meals_wasted / c.meals_uplifted, 2), NULL)                             AS wastage_pct,
       IFF(c.deliveries_total > 0, ROUND(100 * c.deliveries_on_time / c.deliveries_total, 2), NULL)                   AS on_time_catering_delivery_pct,
       c.late_downlifts,
       fl.flights_handled, fl.handling_revenue_usd,
       IFF(fl.flights_handled > 0, ROUND(f.ground_handling_cost_usd / fl.flights_handled, 2), NULL)                   AS cost_per_flight_serviced_usd,
       IFF(fl.flights_handled > 0, ROUND(100 * fl.departures_on_time / fl.flights_handled, 2), NULL)                  AS on_time_departure_pct,
       s.sla_events, s.sla_breaches,
       IFF(s.sla_events > 0, ROUND(100 * (s.sla_events - s.sla_breaches) / s.sla_events, 2), NULL)                    AS sla_compliance_pct,
       w.asset_downtime_cost_usd, w.asset_downtime_hours, w.failures,
       IFF(w.failures > 0, ROUND(m.operating_hours / w.failures, 1), NULL)                                            AS mtbf_hours,
       IFF(w.failures > 0, ROUND(w.repair_hours / w.failures, 2), NULL)                                               AS mttr_hours,
       l.headcount, l.regular_hours, l.overtime_hours, l.contractor_ot_hours, l.labour_cost_usd,
       IFF(l.regular_hours + l.overtime_hours > 0, ROUND(100 * l.overtime_hours / (l.regular_hours + l.overtime_hours), 2), NULL) AS overtime_ratio_pct,
       f.contractor_spend_usd, f.contractor_budget_usd,
       IFF(f.contractor_budget_usd <> 0, ROUND(100 * (f.contractor_spend_usd - f.contractor_budget_usd) / f.contractor_budget_usd, 2), NULL) AS contractor_spend_vs_budget_pct
FROM fin f
LEFT JOIN cat c USING (fiscal_period, entity_code)
LEFT JOIN fl  USING (fiscal_period, entity_code)
LEFT JOIN lab l USING (fiscal_period, entity_code)
LEFT JOIN wo  w USING (fiscal_period, entity_code)
LEFT JOIN met m USING (fiscal_period, entity_code)
LEFT JOIN sla s USING (fiscal_period, entity_code);

-- Group roll-up (intercompany already excluded)
CREATE OR REPLACE VIEW V_KPI_MONTHLY_GROUP AS
SELECT fiscal_period, 'GROUP' AS entity_code, SUM(revenue_usd) AS revenue_usd, SUM(ebitda_usd) AS ebitda_usd, ROUND(100 * SUM(ebitda_usd) / SUM(revenue_usd), 2) AS ebitda_margin_pct,
       SUM(meals_uplifted) AS meals_uplifted, ROUND(SUM(catering_cost_usd) / NULLIF(SUM(meals_uplifted), 0), 3) AS cost_per_meal_usd, ROUND(100 * SUM(meals_wasted) / NULLIF(SUM(meals_uplifted), 0), 2) AS wastage_pct,
       SUM(flights_handled) AS flights_handled, SUM(asset_downtime_cost_usd) AS asset_downtime_cost_usd, SUM(overtime_hours) AS overtime_hours, SUM(contractor_ot_hours) AS contractor_ot_hours,
       ROUND(100 * SUM(overtime_hours) / NULLIF(SUM(regular_hours) + SUM(overtime_hours), 0), 2) AS overtime_ratio_pct
FROM V_KPI_MONTHLY GROUP BY 1;

-- ------------------------------------------------------------------ MEASURE_CATALOG
CREATE OR REPLACE TABLE EDW_GOLD.CONTROL.MEASURE_CATALOG (
  measure_id VARCHAR(10), measure_name VARCHAR(80), kpi_family VARCHAR(30), definition VARCHAR(600), formula VARCHAR(600), unit VARCHAR(12), grain VARCHAR(120),
  owner VARCHAR(60), steward VARCHAR(60), sensitivity VARCHAR(20), refresh_cadence VARCHAR(60), source_systems VARCHAR(120), lineage VARCHAR(400),
  semantic_object VARCHAR(120), dax_measure VARCHAR(60), certified BOOLEAN, certified_on DATE, version VARCHAR(10)
);
INSERT INTO EDW_GOLD.CONTROL.MEASURE_CATALOG VALUES
('M-001','Revenue','Financial','External operating revenue in USD. Excludes intercompany manpower billing (GL 400500).','SUM(-amount_usd) WHERE account_class=''Revenue'' AND NOT is_intercompany','USD','Month x Entity x Cost centre x Airline','Group CFO','Group Finance Data Steward','CONFIDENTIAL','Daily 02:00 (SAP period close: D+1)','SAP S/4HANA','SAP ACDOCA -> BRONZE.SAP_GL_ACTUALS_MONTHLY -> SILVER.SAP_GL_CONFORMED -> GOLD.FACT_FINANCE_POSTING -> V_FINANCE_POSTING','EDW_GOLD.SEMANTIC.V_KPI_MONTHLY.revenue_usd','[Revenue]',TRUE,'2026-10-15','1.2'),
('M-002','EBITDA','Financial','Revenue less cost of sales and operating expenses (GL classes Revenue, COGS, Opex), before depreciation, amortisation, finance costs and zakat/tax. Intercompany excluded.','SUM(-amount_usd) WHERE is_ebitda AND NOT is_intercompany','USD','Month x Entity','Group CFO','Group Finance Data Steward','CONFIDENTIAL','Daily 02:00','SAP S/4HANA','DIM_GL_ACCOUNT.is_ebitda flag governs account inclusion','V_KPI_MONTHLY.ebitda_usd','[EBITDA]',TRUE,'2026-10-15','1.2'),
('M-003','EBITDA Margin %','Financial','EBITDA as a percentage of Revenue.','100 * EBITDA / Revenue','%','Month x Entity','Group CFO','Group Finance Data Steward','CONFIDENTIAL','Daily 02:00','SAP S/4HANA','Derived from M-001, M-002','V_KPI_MONTHLY.ebitda_margin_pct','[EBITDA Margin %]',TRUE,'2026-10-15','1.2'),
('M-004','Revenue vs Budget Variance','Financial','Actual external revenue minus phased budget (SAP CO plan version 0).','SUM(-amount_usd) - SUM(-budget_usd) for Revenue accounts','USD','Month x Entity x Cost centre','Group CFO','Group Finance Data Steward','CONFIDENTIAL','Daily 02:00','SAP S/4HANA','SAP CO plan (COSP) -> BRONZE.SAP_CO_BUDGET_MONTHLY joined in Silver on company/period/CC/GL/profit centre','V_FINANCE_POSTING.variance_usd','[Revenue vs Budget]',TRUE,'2026-10-15','1.0'),
('M-005','Meals Uplifted','Catering Ops','Number of meals loaded onto departing aircraft, all classes, all airlines.','SUM(meals_uplifted)','meals','Day x Airline x Route group x Class x Station','Head of Flight Catering','Catering Data Steward','INTERNAL','Hourly (CMS live feed), daily history','Catering Management System','CMS uplift records -> BRONZE.CMS_UPLIFT_FLIGHT_CLASS / CMS_UPLIFT_DAILY_HISTORY -> SILVER.CMS_UPLIFT_DAILY (dedup on UPLIFT_ID) -> FACT_CATERING_UPLIFT','V_CATERING_UPLIFT.meals_uplifted','[Meals Uplifted]',TRUE,'2026-10-15','1.1'),
('M-006','Cost per Meal Uplifted','Catering Ops','Total production cost (food + allocated labour + overhead) of meals produced, divided by meals uplifted. Wasted meals increase the numerator but not the denominator.','SUM(total_cost_usd) / SUM(meals_uplifted)','USD/meal','Day x Airline x Class (ratio recomputed at every aggregation level)','Head of Flight Catering','Catering Data Steward','CONFIDENTIAL','Hourly / daily','Catering Management System','Cost components are CMS standard costs x produced quantity; GL reconciliation in RECON_RESULTS (Catering cost total)','V_KPI_MONTHLY.cost_per_meal_usd; V_AIRLINE_PNL_MONTHLY.cost_per_meal_usd','[Cost per Meal]',TRUE,'2026-10-15','1.3'),
('M-007','Food Cost per Meal','Catering Ops','Raw material cost component of cost per meal.','SUM(food_cost_usd) / SUM(meals_uplifted)','USD/meal','as M-006','Head of Flight Catering','Catering Data Steward','CONFIDENTIAL','Hourly / daily','Catering Management System','DIM_MEAL.std_food_cost_usd per menu spec version explains step changes (e.g. v3 Jul-2026)','V_CATERING_UPLIFT.food_cost_usd','[Food Cost per Meal]',TRUE,'2026-10-15','1.0'),
('M-008','Labour Cost per Meal','Catering Ops','Allocated kitchen & dispatch labour per meal uplifted, including night-shift premium.','SUM(labour_cost_usd) / SUM(meals_uplifted)','USD/meal','as M-006','Head of Flight Catering','Catering Data Steward','CONFIDENTIAL','Hourly / daily','Catering Management System, SuccessFactors','Night premium factor sourced from SF shift pattern','V_CATERING_UPLIFT.labour_cost_usd','[Labour Cost per Meal]',TRUE,'2026-10-15','1.0'),
('M-009','Wastage %','Catering Ops','Meals produced but not billable (spoiled, over-produced, unused downlift) as a percentage of meals uplifted. Threshold: 4%.','100 * SUM(meals_wasted) / SUM(meals_uplifted)','%','Day x Airline x Route group x Class','Head of Flight Catering','Catering Data Steward','INTERNAL','Hourly / daily','Catering Management System','CMS production orders reconcile produced = uplifted + wasted','V_KPI_MONTHLY.wastage_pct','[Wastage %]',TRUE,'2026-10-15','1.1'),
('M-010','On-time Catering Delivery %','Catering Ops','Share of catered flights where the catering truck completed loading at or before the contractual window (STD - 45 min).','100 * SUM(deliveries_on_time) / SUM(deliveries_total)','%','Day x Airline','Head of Flight Catering','Catering Data Steward','INTERNAL','Hourly / daily','Catering Management System, SITA RMS','Delivery timestamp from CMS dispatch vs STD from SITA/AODB','V_KPI_MONTHLY.on_time_catering_delivery_pct','[On-time Catering Delivery %]',TRUE,'2026-10-15','1.0'),
('M-011','Late Downlift Confirmations','Catering Ops','Count of flights where the airline confirmed downlift quantities after the production cut-off, forcing speculative production.','SUM(late_downlift_confirmations)','count','Day x Airline','Head of Flight Catering','Catering Data Steward','INTERNAL','Hourly / daily','Catering Management System, Oracle airline portal','Portal order amendments after cut-off corroborate','V_CATERING_UPLIFT.late_downlift_confirmations','[Late Downlift Confirmations]',TRUE,'2026-10-15','1.0'),
('M-012','Catering Revenue','Commercial','Billable catering revenue at contract price per meal uplifted (charter: per flight ad hoc).','SUM(revenue_usd)','USD','Day x Airline x Class','Chief Commercial Officer','Commercial Data Steward','CONFIDENTIAL','Hourly / daily','Catering Management System (billing), SAP','Reconciles to GL 400200/400210 by month and airline profit centre','V_CATERING_UPLIFT.revenue_usd','[Catering Revenue]',TRUE,'2026-10-15','1.1'),
('M-013','Revenue per Airline','Commercial','Catering plus ground handling revenue per airline contract.','SUM(catering_revenue_usd + handling_revenue_usd)','USD','Month x Airline','Chief Commercial Officer','Commercial Data Steward','CONFIDENTIAL','Daily','CMS, AODB/SITA, SAP','AGG_MONTHLY_AIRLINE_PNL from FACT_CATERING_UPLIFT + AGG_DAILY_FLIGHTS','V_AIRLINE_PNL_MONTHLY.total_revenue_usd','[Revenue per Airline]',TRUE,'2026-10-15','1.0'),
('M-014','Contribution Margin per Airline','Commercial','Revenue per airline less catering production cost and direct handling cost (standard 82% of handling revenue).','total_revenue_usd - catering_cost_usd - handling_cost_usd','USD','Month x Airline','Chief Commercial Officer','Commercial Data Steward','CONFIDENTIAL','Daily','CMS, AODB/SITA, SAP','Handling cost ratio certified annually by Finance','V_AIRLINE_PNL_MONTHLY.contribution_margin_usd','[Margin per Airline]',TRUE,'2026-10-15','1.0'),
('M-015','Contribution Margin % per Airline','Commercial','Contribution margin as % of revenue per airline.','100 * contribution_margin_usd / total_revenue_usd','%','Month x Airline','Chief Commercial Officer','Commercial Data Steward','CONFIDENTIAL','Daily','CMS, AODB/SITA, SAP','Derived from M-013, M-014','V_AIRLINE_PNL_MONTHLY.contribution_margin_pct','[Margin % per Airline]',TRUE,'2026-10-15','1.0'),
('M-016','Flights Serviced','Ground Ops','Turnarounds handled by ASC group at all stations.','SUM(flights_handled)','flights','Day x Airline x Station x Route group','Head of Ground Operations','Operations Data Steward','INTERNAL','Hourly (SITA MVT)','SITA RMS / AODB','MVT messages -> SILVER.SITA_MOVEMENTS -> AGG_DAILY_FLIGHTS','V_DAILY_FLIGHTS.flights_handled','[Flights Serviced]',TRUE,'2026-10-15','1.0'),
('M-017','Cost per Flight Serviced','Ground Ops','Ground-handling business-unit operating cost (GL, excl. intercompany) divided by flights handled.','SUM(GL cost WHERE business_unit=''Ground Handling'') / SUM(flights_handled)','USD/flight','Month x Entity','Head of Ground Operations','Operations Data Steward','CONFIDENTIAL','Daily','SAP S/4HANA, SITA RMS','Numerator from FACT_FINANCE_POSTING via DIM_COST_CENTER.business_unit; denominator AGG_DAILY_FLIGHTS','V_KPI_MONTHLY.cost_per_flight_serviced_usd','[Cost per Flight]',TRUE,'2026-10-15','1.0'),
('M-018','On-time Departure %','Ground Ops','Departures within 15 minutes of STD (ASC-attributable delay codes only in v2).','100 * SUM(departures_on_time) / SUM(flights_handled)','%','Day x Airline x Station','Head of Ground Operations','Operations Data Steward','INTERNAL','Hourly','SITA RMS','MVT ATD - STD','V_KPI_MONTHLY.on_time_departure_pct','[On-time Departure %]',TRUE,'2026-10-15','1.0'),
('M-019','SLA Compliance %','Commercial','Contractual SLA events met as % of events measured (delivery window, order cut-off, SPML fulfilment, downlift confirmation, complaint response).','100 * (SUM(sla_events) - SUM(sla_breaches)) / SUM(sla_events)','%','Day x Airline','Chief Commercial Officer','Commercial Data Steward','INTERNAL','Daily','Oracle airline portal','PORTAL_ORDERS_DAILY + PORTAL_SLA_EVENTS -> FACT_AIRLINE_ORDER','V_KPI_MONTHLY.sla_compliance_pct','[SLA Compliance %]',TRUE,'2026-10-15','1.0'),
('M-020','Special Meal Fulfilment %','Commercial','SPML orders fulfilled as % of SPML orders received.','100 * (SUM(special_meal_orders) - SUM(special_meals_unfulfilled)) / SUM(special_meal_orders)','%','Day x Airline','Head of Flight Catering','Catering Data Steward','INTERNAL','Daily','Oracle airline portal','FACT_AIRLINE_ORDER','V_AIRLINE_ORDER','[SPML Fulfilment %]',TRUE,'2026-10-15','1.0'),
('M-021','Asset Downtime Cost','Engineering','Hours an asset was unavailable multiplied by the asset-class downtime rate (standby hire / lost productivity).','SUM(downtime_hours * downtime_rate_usd_per_hr)','USD','Work order (Asset x Date)','Head of Engineering','Engineering Data Steward','INTERNAL','Hourly (Maximo)','IBM Maximo','Maximo WO -> SILVER.MAXIMO_WO_CONFORMED -> FACT_WORK_ORDER (rate from DIM_ASSET version in effect)','V_KPI_MONTHLY.asset_downtime_cost_usd','[Asset Downtime Cost]',TRUE,'2026-10-15','1.1'),
('M-022','MTBF (hours)','Engineering','Mean time between failures: operating hours divided by corrective (CM) work orders.','SUM(operating_hours) / COUNT(CM work orders)','hours','Month x Asset','Head of Engineering','Engineering Data Steward','INTERNAL','Daily','IBM Maximo','Meter readings (RUNHOURS) + FACT_WORK_ORDER.is_failure','V_ASSET_RELIABILITY_MONTHLY.mtbf_hours','[MTBF Hours]',TRUE,'2026-10-15','1.0'),
('M-023','MTTR (hours)','Engineering','Mean time to repair: actual start-to-finish hours of corrective work orders divided by their count.','SUM(repair_hours WHERE is_failure) / COUNT(is_failure)','hours','Month x Asset','Head of Engineering','Engineering Data Steward','INTERNAL','Daily','IBM Maximo','ACTSTART/ACTFINISH','V_ASSET_RELIABILITY_MONTHLY.mttr_hours','[MTTR Hours]',TRUE,'2026-10-15','1.0'),
('M-024','Hydraulic Fault Count (3m rolling)','Engineering','Rolling three-month count of HYD-* failure codes per asset; leading indicator for the GSE failure-prediction model.','SUM(hydraulic_faults) OVER 3 months','count','Month x Asset','Head of Engineering','Engineering Data Steward','INTERNAL','Daily','IBM Maximo','FAILURECODE LIKE ''HYD%''','V_ASSET_RELIABILITY_MONTHLY.hydraulic_faults_3m','[Hydraulic Faults 3M]',TRUE,'2026-10-15','1.0'),
('M-025','Headcount','People','Distinct employees and contractors with hours in the period.','COUNT(DISTINCT employee_id)','people','Month x Cost centre x Employment type','CHRO','HR Data Steward','INTERNAL','Daily','SuccessFactors, Contractor feeds','SF time entries + contractor invoice lines -> FACT_LABOUR_COST.headcount (additive only within one cost centre)','V_LABOUR_COST.headcount','[Headcount]',TRUE,'2026-10-15','1.0'),
('M-026','Overtime Hours','People','Approved overtime hours, permanent and contractor.','SUM(overtime_hours)','hours','Month x Cost centre x Employment type x Shift','CHRO','HR Data Steward','INTERNAL','Daily','SuccessFactors, Contractor feeds','FACT_LABOUR_COST','V_KPI_MONTHLY.overtime_hours','[Overtime Hours]',TRUE,'2026-10-15','1.0'),
('M-027','Overtime Ratio %','People','Overtime hours as a share of total paid hours.','100 * SUM(overtime_hours) / (SUM(regular_hours) + SUM(overtime_hours))','%','Month x Cost centre x Employment type','CHRO','HR Data Steward','INTERNAL','Daily','SuccessFactors, Contractor feeds','FACT_LABOUR_COST','V_KPI_MONTHLY.overtime_ratio_pct','[Overtime Ratio %]',TRUE,'2026-10-15','1.0'),
('M-028','Contractor Overtime Hours','People','Overtime hours invoiced by manpower agencies (ASCWF pools).','SUM(overtime_hours) WHERE employment_type=''Contractor''','hours','Month x Pool cost centre x Deployed cost centre','GM ASC Workforce','HR Data Steward','INTERNAL','Daily (agency CSV drop)','Contractor feeds','CONTRACTOR_FEED_* -> SILVER.CONTRACTOR_LINES_CONFORMED (DQ-gated) -> FACT_LABOUR_COST','V_KPI_MONTHLY.contractor_ot_hours','[Contractor OT Hours]',TRUE,'2026-10-15','1.0'),
('M-029','Contractor Spend vs Budget %','Financial','Contractor labour GL (510300/510400) actual versus phased budget.','100 * (actual - budget) / budget WHERE kpi_group=''Contractor Cost'' AND NOT is_intercompany','%','Month x Entity x Cost centre','GM ASC Workforce','Group Finance Data Steward','CONFIDENTIAL','Daily','SAP S/4HANA, Contractor feeds','GL actuals reconcile to invoice lines (RECON: Contractor OT hours by period)','V_KPI_MONTHLY.contractor_spend_vs_budget_pct','[Contractor Spend vs Budget %]',TRUE,'2026-10-15','1.0'),
('M-030','Labour Cost','People','Regular + overtime + benefits (GOSI/allowances) cost of permanent staff and invoiced contractor cost.','SUM(total_cost_usd)','USD','Month x Cost centre x Employment type','CHRO','HR Data Steward','RESTRICTED-PAYROLL','Daily','SuccessFactors, Contractor feeds','Hourly rates masked by MP_HOURLY_RATE; aggregate exposed','V_KPI_MONTHLY.labour_cost_usd','[Labour Cost]',TRUE,'2026-10-15','1.0'),
('M-031','Vendor Spend (golden)','Procurement','Purchase order value in USD by golden vendor after MDM de-duplication.','SUM(amount_usd) GROUP BY vendor_key','USD','PO line','CPO','Procurement Data Steward','CONFIDENTIAL','Daily','SAP S/4HANA, SAP Ariba','VENDOR_XREF maps 97 source ids to 80 golden vendors','FACT_PURCHASE_ORDER joined to DIM_VENDOR','[Vendor Spend]',TRUE,'2026-10-15','1.0'),
('M-032','Data Quality Pass Rate %','Governance','Share of active DQ rules passing on the latest batch.','100 * COUNT(status=''PASS'') / COUNT(*)','%','Batch','Head of Data Governance','Platform Data Steward','INTERNAL','Per batch','Platform','SILVER.DQ.DQ_RESULTS','EDW_SILVER.DQ.DQ_RESULTS','[DQ Pass Rate %]',TRUE,'2026-10-15','1.0');

-- Lineage edges (coarse-grained, feeds the lineage visual in the governance report)
CREATE OR REPLACE TABLE EDW_GOLD.CONTROL.LINEAGE_EDGES (src_object VARCHAR(160), tgt_object VARCHAR(160), transform VARCHAR(200));
INSERT INTO EDW_GOLD.CONTROL.LINEAGE_EDGES VALUES
 ('SAP S/4HANA ACDOCA', 'EDW_BRONZE.RAW.SAP_GL_ACTUALS_MONTHLY', 'Extract D+1 02:00, audit columns'), ('EDW_BRONZE.RAW.SAP_GL_ACTUALS_MONTHLY', 'EDW_SILVER.CONFORMED.SAP_GL_CONFORMED', 'entity map, USD, budget join, dedup'),
 ('EDW_SILVER.CONFORMED.SAP_GL_CONFORMED', 'EDW_GOLD.STAR.FACT_FINANCE_POSTING', 'surrogate keys'), ('EDW_GOLD.STAR.FACT_FINANCE_POSTING', 'EDW_GOLD.SEMANTIC.V_KPI_MONTHLY', 'Revenue, EBITDA, margin, contractor spend'),
 ('CMS uplift API', 'EDW_BRONZE.RAW.CMS_UPLIFT_FLIGHT_CLASS', 'hourly'), ('CMS history export', 'EDW_BRONZE.RAW.CMS_UPLIFT_DAILY_HISTORY', 'one-off backfill'),
 ('EDW_BRONZE.RAW.CMS_UPLIFT_FLIGHT_CLASS', 'EDW_SILVER.CONFORMED.CMS_UPLIFT_LIVE_CLEAN', 'dedup UPLIFT_ID, trim/upper'), ('EDW_SILVER.CONFORMED.CMS_UPLIFT_LIVE_CLEAN', 'EDW_SILVER.CONFORMED.CMS_UPLIFT_DAILY', 'roll-up to daily grain + union history'),
 ('EDW_SILVER.CONFORMED.CMS_UPLIFT_DAILY', 'EDW_GOLD.STAR.FACT_CATERING_UPLIFT', 'keys, menu spec'), ('EDW_GOLD.STAR.FACT_CATERING_UPLIFT', 'EDW_GOLD.AGG.AGG_MONTHLY_AIRLINE_PNL', 'monthly airline P&L'),
 ('IBM Maximo', 'EDW_BRONZE.RAW.MAXIMO_WORK_ORDERS', 'hourly'), ('EDW_BRONZE.RAW.MAXIMO_WORK_ORDERS', 'EDW_GOLD.STAR.FACT_WORK_ORDER', 'via SILVER.MAXIMO_WO_CONFORMED; SCD2 asset lookup'),
 ('Agency CSV drop', 'EDW_BRONZE.RAW.CONTRACTOR_FEED_DAILY', 'strict COPY; rejects -> QUARANTINE'), ('EDW_BRONZE.QUARANTINE.CONTRACTOR_FEED_LENIENT', 'EDW_SILVER.DQ.DQ_QUARANTINE', 'row-level DQ rules'),
 ('EDW_BRONZE.RAW.SAP_VENDOR_MASTER', 'EDW_SILVER.MDM.VENDOR_GOLDEN', 'match CR/IBAN/name, survivorship'), ('EDW_SILVER.MDM.VENDOR_GOLDEN', 'EDW_GOLD.STAR.DIM_VENDOR', 'golden + xref');

-- Demo answers --------------------------------------------------------------
-- Which airline contracts had the highest cost per meal last quarter, and why?
SELECT fiscal_quarter, airline_name, demo_alias,
       ROUND(SUM(total_cost_usd) / SUM(meals_uplifted), 3) AS cost_per_meal,
       ROUND(SUM(food_cost_usd) / SUM(meals_uplifted), 3) AS food_per_meal,
       ROUND(SUM(labour_cost_usd) / SUM(meals_uplifted), 3) AS labour_per_meal,
       ROUND(100 * SUM(meals_wasted) / SUM(meals_uplifted), 2) AS wastage_pct,
       SUM(late_downlift_confirmations) AS late_downlifts, MAX(spec_version) AS menu_spec_version
FROM V_CATERING_UPLIFT WHERE fiscal_quarter IN ('FY26 Q2', 'FY26 Q3')
GROUP BY 1, 2, 3 ORDER BY airline_name, fiscal_quarter;
