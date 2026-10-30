# Power BI model notes - ASC Group Performance (Snowflake Gold)

## Connection
- Connector: **Snowflake** (native). Server `<account>.snowflakecomputing.com`, warehouse `WH_BI`, database `EDW_GOLD`.
- Mode: **Import** for the demo file (fast, works offline for rehearsal); **DirectQuery** composite for the "live refresh" moment - keep `FACT_CATERING_UPLIFT`, `RECON_RESULTS` and `CERTIFICATION_LOG` in DirectQuery, everything else Import (Dual for dimensions).
- Authentication: Snowflake SSO (OAuth) so `CURRENT_ROLE()` / `CURRENT_USER()` reach the row access and masking policies. Set the connection **Role** per persona when testing (`ROLE_FIN_ASC` etc.). With a service-account gateway instead, enable Power BI RLS below.

## Tables (schema.object -> model table)
| Model table | Source | Mode | Notes |
|---|---|---|---|
| DIM_DATE | STAR.DIM_DATE | Dual | Mark as date table on `calendar_date` |
| DIM_ENTITY | STAR.DIM_ENTITY | Dual | |
| DIM_AIRLINE | STAR.DIM_AIRLINE | Dual | `demo_alias` for anonymised slides; `airline_name` in live demo |
| DIM_STATION | STAR.DIM_STATION | Dual | |
| DIM_COST_CENTER | STAR.DIM_COST_CENTER | Dual | `business_unit` drives Cost per Flight (Ground Handling) |
| DIM_GL_ACCOUNT | STAR.DIM_GL_ACCOUNT | Dual | `is_ebitda`, `is_intercompany`, `natural_sign` used by measures |
| DIM_MEAL | STAR.DIM_MEAL | Dual | menu spec version (v2 -> v3 story) |
| DIM_ASSET | STAR.DIM_ASSET | Dual | SCD2: one row per version; `is_current` for slicers |
| DIM_EMPLOYEE | STAR.DIM_EMPLOYEE | Import | masked by Snowflake policy for non-HR roles; never expose in visuals except HR page |
| DIM_VENDOR | STAR.DIM_VENDOR | Dual | |
| FACT_CATERING_UPLIFT | STAR.FACT_CATERING_UPLIFT | DQ/Import | 17.8k rows |
| FACT_FINANCE_POSTING | STAR.FACT_FINANCE_POSTING | Import | 7.1k rows |
| FACT_WORK_ORDER | STAR.FACT_WORK_ORDER | Import | 1.1k rows |
| FACT_LABOUR_COST | STAR.FACT_LABOUR_COST | Import | 3.2k rows |
| FACT_AIRLINE_ORDER | STAR.FACT_AIRLINE_ORDER | Import | 5.7k rows |
| FACT_PURCHASE_ORDER | STAR.FACT_PURCHASE_ORDER | Import | 2.2k rows |
| AGG_DAILY_FLIGHTS | AGG.AGG_DAILY_FLIGHTS | Import | 16.8k rows |
| AGG_MONTHLY_AIRLINE_PNL | AGG.AGG_MONTHLY_AIRLINE_PNL | Import | 442 rows |
| AGG_MONTHLY_ASSET_RELIABILITY | AGG.AGG_MONTHLY_ASSET_RELIABILITY | Import | 840 rows |
| RECON_RESULTS | CONTROL.RECON_RESULTS | DirectQuery | governance page |
| CERTIFICATION_LOG | CONTROL.CERTIFICATION_LOG | DirectQuery | footer "Certified as of" |
| MEASURE_CATALOG | CONTROL.MEASURE_CATALOG | Import | tooltip page: definition, owner, lineage per KPI |
| DQ_RESULTS / DQ_QUARANTINE | EDW_SILVER.DQ.* | DirectQuery | governance page (audit persona only) |

Hide all `*_key` columns and `src_batch_id`. Keep `src_batch_id` reachable via a drill-through "Lineage" page.

## Relationships (all many-to-one, single direction, from fact to dimension)
```
FACT_CATERING_UPLIFT[date_key]        -> DIM_DATE[date_key]
FACT_CATERING_UPLIFT[entity_key]      -> DIM_ENTITY[entity_key]
FACT_CATERING_UPLIFT[station_key]     -> DIM_STATION[station_key]
FACT_CATERING_UPLIFT[airline_key]     -> DIM_AIRLINE[airline_key]
FACT_CATERING_UPLIFT[meal_key]        -> DIM_MEAL[meal_key]
FACT_FINANCE_POSTING[date_key]        -> DIM_DATE[date_key]
FACT_FINANCE_POSTING[entity_key]      -> DIM_ENTITY[entity_key]
FACT_FINANCE_POSTING[cost_center_key] -> DIM_COST_CENTER[cost_center_key]
FACT_FINANCE_POSTING[gl_account_key]  -> DIM_GL_ACCOUNT[gl_account_key]
FACT_FINANCE_POSTING[airline_key]     -> DIM_AIRLINE[airline_key]          (nullable; cost rows have no airline)
FACT_WORK_ORDER[date_key]             -> DIM_DATE[date_key]
FACT_WORK_ORDER[asset_key]            -> DIM_ASSET[asset_key]              (SCD2 version key - NOT asset_id)
FACT_WORK_ORDER[entity_key]           -> DIM_ENTITY[entity_key]
FACT_WORK_ORDER[station_key]          -> DIM_STATION[station_key]
FACT_WORK_ORDER[cost_center_key]      -> DIM_COST_CENTER[cost_center_key]
FACT_LABOUR_COST[date_key]            -> DIM_DATE[date_key]
FACT_LABOUR_COST[entity_key]          -> DIM_ENTITY[entity_key]
FACT_LABOUR_COST[cost_center_key]     -> DIM_COST_CENTER[cost_center_key]  (active)
FACT_LABOUR_COST[deployed_cost_center_key] -> DIM_COST_CENTER[cost_center_key]  (inactive; use USERELATIONSHIP for "deployed to" views)
FACT_AIRLINE_ORDER[date_key]          -> DIM_DATE[date_key]
FACT_AIRLINE_ORDER[airline_key]       -> DIM_AIRLINE[airline_key]
FACT_AIRLINE_ORDER[entity_key]        -> DIM_ENTITY[entity_key]
FACT_AIRLINE_ORDER[station_key]       -> DIM_STATION[station_key]
FACT_PURCHASE_ORDER[date_key]         -> DIM_DATE[date_key]
FACT_PURCHASE_ORDER[entity_key]       -> DIM_ENTITY[entity_key]
FACT_PURCHASE_ORDER[cost_center_key]  -> DIM_COST_CENTER[cost_center_key]
FACT_PURCHASE_ORDER[gl_account_key]   -> DIM_GL_ACCOUNT[gl_account_key]
FACT_PURCHASE_ORDER[vendor_key]       -> DIM_VENDOR[vendor_key]
AGG_DAILY_FLIGHTS[date_key]           -> DIM_DATE[date_key]
AGG_DAILY_FLIGHTS[entity_key]         -> DIM_ENTITY[entity_key]
AGG_DAILY_FLIGHTS[station_key]        -> DIM_STATION[station_key]
AGG_DAILY_FLIGHTS[airline_key]        -> DIM_AIRLINE[airline_key]
AGG_MONTHLY_AIRLINE_PNL[airline_key]  -> DIM_AIRLINE[airline_key]
AGG_MONTHLY_AIRLINE_PNL[fiscal_period]-> DIM_PERIOD[fiscal_period]        (DIM_PERIOD = DISTINCT(DIM_DATE[fiscal_period]) calculated table; or relate to DIM_DATE via a period-end date column)
AGG_MONTHLY_ASSET_RELIABILITY[asset_key] -> DIM_ASSET[asset_key]
AGG_MONTHLY_ASSET_RELIABILITY[fiscal_period] -> DIM_PERIOD[fiscal_period]
DIM_COST_CENTER[entity_key]           -> DIM_ENTITY[entity_key]            (snowflaked; fine for slicer propagation, keep single direction)
DIM_ASSET[station_key]                -> DIM_STATION[station_key]
```
Create `DIM_PERIOD = SUMMARIZE(DIM_DATE, DIM_DATE[fiscal_period], DIM_DATE[fiscal_quarter], DIM_DATE[fiscal_year])` and relate `DIM_DATE[fiscal_period] -> DIM_PERIOD[fiscal_period]` (many-to-one, DIM_DATE side many) so month slicers flow to both daily and monthly facts.

## Row-level security
Preferred: **none in Power BI** - connect with SSO so Snowflake row access policies (`06_security_rls.sql`) do the work; the same report shows four entities to the Group Exec and one to ASC Finance with zero report logic.

Fallback (gateway / service account) - create these PBI roles mirroring the Snowflake personas:
| PBI role | DAX filter |
|---|---|
| Group Exec | (none) |
| Finance ASC | `DIM_ENTITY[entity_code] = "ASC"` |
| Station Manager BYP | `DIM_STATION[station_code] = "BYP"` |
| HR BP | (none on rows; HR page visible via page-level navigation only) |
| Airline AM | `DIM_AIRLINE[airline_code] IN { "BA", "EK", "FZ", "CHR" }` - or dynamic: `LOOKUPVALUE(PERSONA_AIRLINE_MAP[airline_key], PERSONA_AIRLINE_MAP[user_name], USERPRINCIPALNAME()) = DIM_AIRLINE[airline_key]` after importing `SECURITY.PERSONA_AIRLINE_MAP` |
| Internal Audit | (none) |
Object-level security (Tabular Editor): hide `DIM_EMPLOYEE[monthly_salary_usd]`, `[housing_allowance_usd]`, `[national_id]`, `[date_of_birth]`, `[work_email]` from every role except HR BP. Column masking still happens in Snowflake when SSO is used, so OLS is belt-and-braces.

## Report pages (Demo 1)
1. **Group Scorecard** - cards: Revenue, EBITDA, EBITDA Margin %, Cost per Meal, Cost per Flight Serviced, SLA Compliance %, Wastage %, Overtime Ratio %; footer `[Last Refresh Label]`.
2. **Catering Cost per Meal** - matrix airline x quarter with `[Cost per Meal]`, `[Cost per Meal Δ vs PQ %]`; decomposition tree: Cost per Meal -> Food/Labour/Overhead per meal -> Menu spec version -> Late downlift rate. Highlight Emirates, flydubai, Charter FY26 Q3 (+12-13%).
3. **Wastage by Route Group** - map/bar by `route_group`, conditional formatting at 4%; Gulfway Airways Europe Sep-2026 = 4.6%.
4. **Airline P&L** - revenue & margin % per airline (AGG_MONTHLY_AIRLINE_PNL), account-manager slicer (RLS demo).
5. **GSE Reliability** - T-114 line chart downtime cost vs `[Downtime Cost 6M Baseline]`, column chart `[Hydraulic Faults 3M]`, MTBF/MTTR table; asset status from SCD2 ("Watch List - Hydraulic" from 20 Aug 2026).
6. **People & Contractors** - `[Overtime Ratio %]` by shift, `[Contractor OT Δ vs PM (hrs)]` = +318 for ASCWF in Sep-2026, Contractor Spend vs Budget %.
7. **Governance** (audit persona) - RECON_RESULTS latest run, DQ scorecard, quarantine rows, MEASURE_CATALOG as a searchable table, vendor MDM (97 -> 80).

## Formatting
- USD, 0 decimals, thousands separator; cost per meal 3 decimals; percentages 1 decimal.
- Use `DIM_AIRLINE[demo_alias]` on any page that may be screenshotted for slides; swap to `airline_name` live.
