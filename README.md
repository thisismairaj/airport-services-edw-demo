# Airport services EDW demo: Snowflake medallion platform, Power BI, Streamlit and Cortex Analyst

An end-to-end, synthetic demo of an enterprise data platform for **Airport Services Co. (ASC)**, a fictional airport
ground-handling and flight-catering group based at the fictional **Bayport International Airport (BYP)**, with a Saudi
subsidiary at Dammam and Riyadh: **8 source systems -> Bronze -> Silver -> Gold star schema -> certified semantic layer ->
Power BI / Streamlit / Cortex Analyst**, with reconciliation, data-quality quarantine, vendor MDM, SCD2, persona-based
security, an ADLS Gen2 + Snowpipe landing zone and an email alert.

Everything here is fictitious and generated (deterministic, seed 42): the company, its entities (ASC, ASC Development,
ASC Saudi Arabia, ASC Workforce Services), its home airport and home airline (Gulfway Airways, GC), people, vendors and all
numbers. Other airline names are real IATA carriers used only as contract labels, with `demo_alias` (Carrier A-I) for
fully anonymised material. Period Jan-2025 .. Sep-2026, group currency USD (Saudi entity in SAR), ~146 flights/day.

```
airport-services-edw-demo/
  generate_data.py            generator (python3 -I generate_data.py; ~15 s; rewrites data/)
  verify_pack.py              CSV<->DDL alignment, FK integrity, story checks, YAML parse, SQL sanity
  data/
    bronze/  (20 CSV)         raw extracts per source object, audit cols src_system/extracted_at/batch_id/row_hash
    gold/    (20 CSV)         DIM_* / FACT_* / AGG_* exactly matching sql/04 DDL (fast-path seeds)
    bad_files/                contractor_feed_2026-09-28_malformed.csv  (quarantine demo)
                              contractor_feed_2026-09-28_clean.csv      (corrected re-drop)
    control_totals.json       headline numbers the demo should show
  sql/
    01_snowflake_setup.sql    DBs EDW_BRONZE/SILVER/GOLD, WH_ELT/WH_BI, 6 persona roles + ROLE_ELT_ADMIN, stages, file formats
    02_bronze_load.sql        CREATE TABLE + COPY INTO per source; quarantine flow for the bad file
    03_silver_transform.sql   harmonisation maps, dedup/conform, vendor MDM (97 -> 80), DQ rules/results/quarantine
    04_gold_model.sql         star DDL, loads from Silver, SCD2 DIM_ASSET, aggregates, certification stamp
    05_reconciliation.sql     control totals -> GOLD.CONTROL.RECON_RESULTS (balance, count, measure, hash)
    06_security_rls.sql       row access policies, masking policies, persona mapping tables, tags
    07_semantic_measures.sql  SEMANTIC views, V_KPI_MONTHLY, MEASURE_CATALOG (32 measures), lineage edges
    08_cortex_analyst_semantic_model.yaml   Cortex Analyst model over the SEMANTIC views, 8 verified queries
    08b_semantic_view.sql                   creates the semantic view GROUP_PERFORMANCE from 08 (Snowflake's current format)
    09_gold_seed_fast_path.sql              load Gold straight from the CSV seeds (rehearsal / Power BI authoring)
    10_live_pipeline.sql                    live SITA feed: stream + task graph Bronze -> Silver -> Gold LIVE_FLIGHT_BOARD
  powerbi/
    measures.dax              ~70 DAX measures for the certified KPIs (catalog ids in comments)
    model_notes.md            tables, relationships, RLS/OLS, report pages
```

## Configure before running

The repo carries no account details. Replace these placeholders with your own:

| Placeholder | Where | What |
|---|---|---|
| `<SNOWFLAKE_ACCOUNT>` | Power BI > Transform data > Edit parameters (`SnowflakeServer`) | Snowflake account identifier, e.g. `myorg-myaccount` |
| `<AZURE_TENANT_ID>` | `sql/01b_adls_integration.sql` | Entra tenant of the Azure subscription holding the landing storage |
| `<ALERT_EMAIL>` | `sql/11_wastage_alert.sql` (two places) | An address verified on a Snowflake user (Snowflake only emails verified addresses) |

Azure resource names (`rg-edw-demo`, storage account `edwdemolanding`) are defaults in `azure/*.sh` and `sql/01b`, `01c`;
storage account names are global, so pick your own if it is taken.

## Source systems -> Bronze objects

| Source | Bronze table(s) | Grain / period shipped |
|---|---|---|
| SAP S/4HANA | SAP_GL_ACTUALS_MONTHLY, SAP_CO_BUDGET_MONTHLY, SAP_PURCHASE_ORDERS, SAP_VENDOR_MASTER | month x company x CC x GL x profit centre (ASCSA in SAR + USD); 2,200 PO lines; 97 vendors |
| SAP SuccessFactors | SF_EMPLOYEE_MASTER, SF_TIME_ENTRIES_MONTHLY | 1,200 permanents (+8 dup rows); approved hours Jan-Sep 2026 |
| SAP Ariba | ARIBA_SUPPLIERS, ARIBA_REQUISITIONS | 77 suppliers (incl. the 17 Ariba-created duplicates), 900 requisitions |
| IBM Maximo | MAXIMO_ASSETS, MAXIMO_WORK_ORDERS, MAXIMO_METER_READINGS | 40 GSE assets, 1,135 work orders (PM + CM), monthly run-hours |
| Catering Management System | CMS_UPLIFT_FLIGHT_CLASS (Sep-2026 live, flight x class), CMS_UPLIFT_DAILY_HISTORY (Jan-25..Aug-26 daily), CMS_PRODUCTION_ORDERS, CMS_MENU_COST | 6,730 live rows incl. 26 duplicates / 20 lower-case carriers / 20 padded destinations |
| Oracle airline portals | PORTAL_ORDERS_DAILY, PORTAL_SLA_EVENTS, PORTAL_SPECIAL_MEALS_MONTHLY | daily x airline; 3,000 SLA events |
| SITA RMS | SITA_MESSAGES | MVT + CAT messages, 16-30 Sep 2026 (3,825 rows) |
| Contractor feeds | CONTRACTOR_FEED_INVOICE_LINES (Jan-25..Aug-26), CONTRACTOR_FEED_DAILY (loaded live from bad_files/) | 400 contractors, monthly invoice lines |

## Built-in stories (all computable from Gold)

| Story | Where to look | Expected numbers |
|---|---|---|
| (a) Q3 FY26 cost per meal rises for Charter, Carrier E (Emirates), Carrier F (flydubai) | V_CATERING_UPLIFT; DIM_MEAL spec v3 from 1-Jul-2026 | Q3 vs Q2 FY26: EK **+13.2%**, FZ **+13.1%**, CHR **+12.4%**; all other airlines < 1%. Drivers: food/meal +12% (menu spec v3), labour/meal +22% (night-shift OT), wastage x1.8, late downlift confirmations 5% -> 22% of flights, SLA breaches 3% -> 8.5% |
| (b) Tug T-114 downtime-cost spike & hydraulic faults | V_ASSET_RELIABILITY_MONTHLY, DIM_ASSET SCD2 | HYD faults per month Mar..Sep 2026: 1,1,1,2,2,3,5; downtime cost Sep-2026 **USD 4,658** vs ~USD 1,300 six-month baseline; status version 3 "Watch List - Hydraulic" from 20-Aug-2026; moved to CC 1102 (night ramp) 1-May-2026 |
| (c) Contractor overtime spike at ASCWF, Sep-2026 | V_LABOUR_COST (employment_type = Contractor) | OT hours Aug 9,343 -> Sep 9,661 = **+318 h** exactly |
| (d) Wastage > 4% on GC Europe routes, Sep-2026 | V_CATERING_UPLIFT route_group = Europe | GC Europe wastage Jun 2.24% -> Jul 2.32% -> Aug 3.14% -> **Sep 4.58%** |
| (e) Duplicate vendor master records | SILVER.MDM.VENDOR_XREF, DIM_VENDOR | **97 source records -> 80 golden, 17 duplicates** (Ariba-sync re-creations: case/punctuation/L.L.C. variants, same CR number + IBAN) |
| (f) Malformed contractor CSV | bad_files/contractor_feed_2026-09-28_malformed.csv | 12 of 14 columns (DEPLOYED_CC, OT_RATE_USD missing), 3 bad dates (`31/02/2026`, `2026-13-01`, `N/A`), negative hours (-12, -208), 612 OT hours, `TBC` amount, `USD 2.75` rate, blank contractor id, vendor `V1OO212`, 3 duplicate lines -> file rejected, 373 rows quarantined with rule ids; clean re-drop loads 370 rows |
| Group P&L | V_KPI_MONTHLY_GROUP | FY2025 revenue USD 84.2M, EBITDA 24.0%; FY2026 YTD (9 m) USD 64.0M, 22.8% (intercompany excluded) |

## Load order

0. Regenerate if needed: `python3 -I generate_data.py && python3 -I verify_pack.py`
1. `sql/01_snowflake_setup.sql` (ACCOUNTADMIN)
2. Upload files (SnowSQL; or Snowsight > Data > Stages > "+ Files"):
   ```
   PUT file://<pack>/data/bronze/*.csv    @EDW_BRONZE.LANDING.STG_SOURCE_DROP/bronze/    AUTO_COMPRESS=FALSE;
   PUT file://<pack>/data/bad_files/*.csv @EDW_BRONZE.LANDING.STG_SOURCE_DROP/bad_files/ AUTO_COMPRESS=FALSE;
   PUT file://<pack>/data/gold/*.csv      @EDW_GOLD.STAR.STG_GOLD_SEED/                  AUTO_COMPRESS=FALSE;
   ```
3. **Full path (the live demo):** `04` DDL section first (tables must exist for `03` reference masters) -> `02` -> `03` -> `04` loads -> `05` -> `06` -> `07`.
   Simplest: run `04_gold_model.sql` once up to the line `-- LOADS FROM SILVER`, then run `02`, `03`, `04` (whole), `05`, `06`, `07`.
   **Fast path (rehearsal / Power BI authoring):** `01` -> `04` DDL section -> `09` -> `06` -> `07`.
4. Cortex Analyst: run `sql/08b_semantic_view.sql`. It creates the semantic view `EDW_GOLD.SEMANTIC.GROUP_PERFORMANCE` from the YAML in `08` (Snowflake now recommends semantic views over YAML model files). In Snowsight: AI & ML > Cortex Analyst > Semantic views > GROUP_PERFORMANCE.
5. Power BI: open `powerbi/ASC_Group_Performance.pbip` (model and measures documented in `powerbi/model_notes.md` and `powerbi/measures.dax`), set the `SnowflakeServer` parameter to your account, sign in, Refresh.
6. Live feed (optional): run `sql/10_live_pipeline.sql`. New rows in `EDW_BRONZE.RAW.SITA_MESSAGES` with `BATCH_ID = 'SITA_LIVE'` then flow to `EDW_GOLD.AGG.LIVE_FLIGHT_BOARD` within about a minute; each run is logged in `EDW_GOLD.CONTROL.PIPELINE_RUN_LOG`. In Snowsight: EDW_BRONZE > LANDING > Tasks > T_SITA_SILVER > Graph.

## Landing zone option: ADLS Gen2 + Snowpipe

Instead of `PUT`ting the CSVs from a laptop, the source files can live in an **ADLS Gen2 container in UAE North** (the same region as
the Snowflake account, so the data never leaves the UAE). Snowflake reads it through a storage integration (an Entra app, no keys in
any script), and a file that lands in `landing/bronze/` is loaded into its Bronze table by **Snowpipe** within about a minute.

**One-time setup** (Azure CLI signed in, then ACCOUNTADMIN in Snowflake):
1. `bash azure/01_setup_adls.sh`: resource group, storage account `edwdemolanding` (hierarchical namespace on), container `landing`, storage queue, Event Grid subscription for new files under `bronze/`.
2. `sql/01b_adls_integration.sql`: the storage integration `INT_EDW_ADLS` and the notification integration `NINT_EDW_LANDING`. It prints two consent links: open each and click Accept once.
3. `bash azure/02_grant_snowflake.sh <storage app name> <queue app name>` (the `AZURE_MULTI_TENANT_APP_NAME` of each integration): gives the two apps their least-privilege roles.
4. `bash azure/03_upload.sh`: uploads `data/` to the container (`bronze/`, `bad_files/`, `gold_seed/`), except the files in `HOLD_BACK`, then clears the event queue.

**Each build** (`LANDING=adls bash edw_rebuild.sh`, or by hand): `01`, then `01c_adls_stages.sql` (replaces `STG_SOURCE_DROP` and `STG_GOLD_SEED` with ADLS stages of the same names, so every `COPY INTO` in `02`, `03`, `04` and `09` is unchanged; `STG_QUARANTINE` stays internal), then the normal load order. After the initial load, run `sql/02b_snowpipe.sql`: 20 pipes, one per feed.

**The live moment:** hold a few files back (`HOLD_BACK`, default `portal_sla_events.csv` and `sita_messages.csv`), build, then `bash azure/04_drop_held_back.sh <file>` and watch the file arrive in Bronze (`SELECT SYSTEM$PIPE_STATUS('EDW_BRONZE.LANDING.PIPE_<TABLE>')`, `COPY_HISTORY`). `--reset <file>` removes it again.

Things to know:
- **Bronze only.** A pipe loads the file into Bronze; Silver and Gold are built by the scripts (`03`, `04`), so a new file reaches Gold when those are run.
- **Never re-drop a file the initial `COPY` already loaded.** A pipe has its own load history, so it would load that file a second time. Held-back files are absent at the first load, so they are safe.
- **A pipe skips a bad file** (`ON_ERROR = SKIP_FILE`) instead of aborting; look at `COPY_HISTORY` for the reason. The strict `ABORT_STATEMENT` behaviour belongs to the initial `COPY`.
- **Cost:** a few cents a month for storage and events. The file listing, `bad_files/` and quarantine steps work unchanged against ADLS.

## Wastage alert by email

`sql/11_wastage_alert.sql` sends an email when an airline-route's wastage goes above the **4%** threshold in the latest month.
A Snowflake ALERT (`EDW_GOLD.CONTROL.AL_WASTAGE_ABOVE_4`) checks every 15 minutes whether there is a breach not yet reported; if so it calls
`SP_WASTAGE_ALERT`, which emails the new breaches through the email integration `INT_EMAIL_ALERTS` and records them in `ALERT_LOG`, so each
airline-route is reported once per month. The email lists each route with its wastage and the month before.

- **Recipients** must be verified on a Snowflake user (Snowflake refuses others). Change them in the integration and in the procedure.
- **It is created suspended.** `ALTER ALERT EDW_GOLD.CONTROL.AL_WASTAGE_ABOVE_4 RESUME;` starts the schedule; or run it by hand at the right moment: `CALL EDW_GOLD.CONTROL.SP_WASTAGE_ALERT(TRUE);`
- **Test without sending anything:** `CALL EDW_GOLD.CONTROL.SP_WASTAGE_ALERT(FALSE);` returns the email it would send.
- **Trigger:** above 4% and not yet reported. In Sep 2026 that is Charter, Gulfway Airways Europe, flydubai GCC and Emirates GCC; only Gulfway Airways Europe crossed this month (3.14% to 4.58%).
- It watches Gold, so it sees new data once Silver and Gold have been rebuilt. `edw_rebuild.sh` recreates it after every rebuild.

## Demo 1 script: ingest -> orchestrate -> reconcile -> conform/model -> certify

Each step names the exact SQL to run on screen (role `ROLE_ELT_ADMIN`, warehouse `WH_ELT`) and what the audience should see.
Pre-stage everything through step 2 of the load order before the session; the demo itself takes 20-25 minutes.

### Step 1 - Ingest (Bronze)  [~4 min]
Run the COPY block of `sql/02_bronze_load.sql` (20 strict loads), then the inventory query at the end of the file.
```sql
SELECT 'CMS_UPLIFT_FLIGHT_CLASS' AS object, COUNT(*) AS rows_landed, MIN(extracted_at), MAX(extracted_at), COUNT(DISTINCT batch_id) FROM EDW_BRONZE.RAW.CMS_UPLIFT_FLIGHT_CLASS
UNION ALL SELECT 'SAP_GL_ACTUALS_MONTHLY', COUNT(*), MIN(extracted_at), MAX(extracted_at), COUNT(DISTINCT batch_id) FROM EDW_BRONZE.RAW.SAP_GL_ACTUALS_MONTHLY
UNION ALL SELECT 'SF_EMPLOYEE_MASTER', COUNT(*), MIN(extracted_at), MAX(extracted_at), COUNT(DISTINCT batch_id) FROM EDW_BRONZE.RAW.SF_EMPLOYEE_MASTER;
```
*See:* 20 source objects landed with `src_system / extracted_at / batch_id / row_hash` on every row; 21 monthly batches for SAP; raw defects still present (lower-case `ek`, duplicate `UPLIFT_ID`s):
```sql
SELECT CARRIER, COUNT(*) FROM EDW_BRONZE.RAW.CMS_UPLIFT_FLIGHT_CLASS GROUP BY 1 ORDER BY 1;          -- 'ek', 'fz', 'gf' appear next to 'EK', 'FZ', 'GC'
SELECT UPLIFT_ID, COUNT(*) FROM EDW_BRONZE.RAW.CMS_UPLIFT_FLIGHT_CLASS GROUP BY 1 HAVING COUNT(*) > 1; -- 26 duplicates
```

### Step 2 - Orchestrate the daily drop and quarantine the bad file  [~5 min]
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
In production the same sequence is a Snowflake Task / Airflow DAG triggered by the stage directory event; here it is run by hand so the audience sees each decision.

### Step 3 - Conform (Silver): dedup, harmonise, MDM, DQ  [~5 min]
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

### Step 4 - Model (Gold star schema, SCD2, aggregates)  [~4 min]
Run `sql/04_gold_model.sql` (loads section). Show:
```sql
SELECT asset_key, asset_id, version_no, cost_center_code, station_code, status, effective_from, effective_to, is_current
FROM EDW_GOLD.STAR.DIM_ASSET WHERE asset_id = 'T-114' ORDER BY version_no;                  -- 3 versions
SELECT fiscal_period, failures, hydraulic_faults, downtime_hours, downtime_cost_usd, mtbf_hours, mttr_hours
FROM EDW_GOLD.AGG.AGG_MONTHLY_ASSET_RELIABILITY WHERE asset_id = 'T-114' AND fiscal_period >= '2026-01' ORDER BY 1;
SELECT * FROM EDW_GOLD.CONTROL.CERTIFICATION_LOG ORDER BY certified_at DESC;              -- status CERTIFIED, content hash per fact
```
*See:* T-114 moves cost centre in May-2026, goes on the hydraulic watch list 20-Aug-2026, and the monthly reliability line shows faults 1,1,1,2,2,3,5 with downtime cost climbing to USD 4,658 in September. Work orders point at the asset *version* in force on the day (SCD2 lookup).

### Step 5 - Reconcile  [~3 min]
Run `sql/05_reconciliation.sql`, then:
```sql
SELECT status, COUNT(*) FROM EDW_GOLD.CONTROL.RECON_RESULTS WHERE run_id = (SELECT MAX(run_id) FROM EDW_GOLD.CONTROL.RECON_RESULTS) GROUP BY 1;
SELECT * FROM EDW_GOLD.CONTROL.V_RECON_LATEST;
```
*See:* GL balance Bronze = Gold for every entity x month (84 rows PASS, variance 0.00), budget totals PASS, meals uplifted by period PASS with the note "26 duplicates removed in Silver", row lineage 6,730 -> 6,704, downtime hours PASS, contractor OT hours per period PASS (incl. Sep-2026 from the corrected file), row-hash set equality PASS, aggregate hash Silver = Gold PASS; INFO rows for vendor 97 -> 80 and quarantined 373 / accepted 370.

### Step 6 - Certify and consume  [~4 min]
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

## Caveats (say them before someone asks)

- **Synthetic.** Volumes, prices and salaries are plausible for a Bayport ground-handling/catering group but invented. Revenue USD ~84M/yr, 1,200 staff + 400 contractors, 40 GSE assets, ~146 turnarounds/day.
- **Size trade-offs (pack < 15 MB).** Bronze CMS is flight x class only for Sep-2026 (live window); earlier months ship as a daily backfill extract (`CMS_UPLIFT_DAILY_HISTORY`). SF time entries ship for 2026 only (2025 labour in Gold comes from the seed, so the SQL path's `FACT_LABOUR_COST` has permanents for 2026 and contractors for the full period). SITA messages cover 16-30 Sep 2026; `AGG_DAILY_FLIGHTS` history is a seed (`09`) that `04` refreshes from SITA. The Gold CSVs therefore contain slightly more history than a pure 02->04 rebuild; the recon checks are scoped to periods present in Bronze.
- **Catering labour in the fact is an allocated standard cost** (per-meal rate x produced meals, night premium), not the SuccessFactors payroll; the GL carries actual payroll. Both are stated in the measure catalog (M-008 vs M-030).
- **Handling cost per airline** in `AGG_MONTHLY_AIRLINE_PNL` uses a certified 82% cost ratio of handling revenue; `cost_per_flight_serviced` at entity level uses actual Ground Handling GL cost.
- **Intercompany**: ASCWF bills ASC for contractors (GL 400500 revenue / 510700 cost). Group revenue/EBITDA exclude it via `DIM_GL_ACCOUNT.is_intercompany`; entity P&Ls include it.
- **SQL not executed against a live account** here; it is written to current Snowflake syntax (QUALIFY, MERGE, COPY FILES, row access/masking policies, HASH_AGG, MATCH_BY_COLUMN_NAME) and checked for CSV/DDL alignment and balanced syntax by `verify_pack.py`. Run `01` as ACCOUNTADMIN once in the demo account the day before.
- `row_hash` is a 12-hex-character MD5 prefix (size), fine for the lineage demo; use full MD5/SHA2 in production.
- Employee names, IDs, e-mails (`@asc-demo.example`) and vendor names are generated; no real person or company data.
