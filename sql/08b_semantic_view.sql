-- =============================================================================
-- 08b_semantic_view.sql  |  Cortex Analyst semantic view (built from 08_cortex_analyst_semantic_model.yaml)
-- Snowflake now recommends semantic views over YAML semantic model files (Snowsight: "Support for semantic
-- models will end soon"). This creates EDW_GOLD.SEMANTIC.GROUP_PERFORMANCE from the same YAML, so the
-- definitions stay in one place: edit the YAML, then re-run this file (the YAML below is a copy of 08).
-- Snowsight: AI & ML > Cortex Analyst > Semantic views > GROUP_PERFORMANCE.
-- =============================================================================
USE ROLE ROLE_ELT_ADMIN;
USE WAREHOUSE WH_ELT;

CALL SYSTEM$CREATE_SEMANTIC_VIEW_FROM_YAML('EDW_GOLD.SEMANTIC', $$
# =============================================================================
# 08_cortex_analyst_semantic_model.yaml  |  Snowflake Cortex Analyst semantic model
# Upload:  PUT file://sql/08_cortex_analyst_semantic_model.yaml @EDW_GOLD.SEMANTIC.STG_SEMANTIC_MODELS;
#          (CREATE STAGE EDW_GOLD.SEMANTIC.STG_SEMANTIC_MODELS; is in README step 5)
# Scope: the certified Gold semantic views only. Row access and masking policies apply to every answer.
# =============================================================================
name: group_performance
description: >
  Certified operational and financial performance model for Airport Services Co. (ASC) group:
  flight catering uplift and cost per meal, finance P&L (revenue, EBITDA, budget variance), ground handling
  flights serviced, GSE asset reliability (downtime cost, MTBF/MTTR, hydraulic faults), labour and contractor
  overtime, airline SLA compliance. Currency is US Dollar (USD). Fiscal year equals calendar year
  (FY26 Q3 = Jul-Sep 2026). Period covered: Jan 2025 - Sep 2026.

tables:
  # ---------------------------------------------------------------- catering
  - name: catering_uplift
    description: Daily catering uplift per airline, route group, meal class and station with production cost, revenue, wastage, on-time delivery and late downlift confirmations.
    base_table:
      database: EDW_GOLD
      schema: SEMANTIC
      table: V_CATERING_UPLIFT
    primary_key:
      columns: [CATERING_UPLIFT_KEY]
    time_dimensions:
      - name: flight_date
        expr: FLIGHT_DATE
        data_type: DATE
        description: Departure date of the catered flights.
        synonyms: ["date", "day", "departure date"]
    dimensions:
      - name: catering_uplift_key
        expr: CATERING_UPLIFT_KEY
        data_type: NUMBER
        description: Surrogate row key (unique per row). Declared so it can serve as the table key.
        unique: true
      - name: fiscal_period
        expr: FISCAL_PERIOD
        data_type: VARCHAR
        description: Month as YYYY-MM.
        synonyms: ["month", "period"]
        sample_values: ["2026-07", "2026-08", "2026-09"]
      - name: fiscal_quarter
        expr: FISCAL_QUARTER
        data_type: VARCHAR
        description: Fiscal quarter label, e.g. FY26 Q3 = Jul-Sep 2026. "Last quarter" as of Oct 2026 means FY26 Q3.
        synonyms: ["quarter", "qtr"]
        sample_values: ["FY25 Q1", "FY26 Q2", "FY26 Q3"]
      - name: fiscal_year
        expr: FISCAL_YEAR
        data_type: NUMBER
        synonyms: ["year", "FY"]
      - name: entity_code
        expr: ENTITY_CODE
        data_type: VARCHAR
        description: Legal entity providing the service (ASC = ASC B.S.C.(c) at Bayport; ASCSA = ASCSA Saudi Arabia at Dammam/Riyadh).
        synonyms: ["legal entity", "company"]
        sample_values: ["ASC", "ASCSA"]
      - name: station_code
        expr: STATION_CODE
        data_type: VARCHAR
        description: IATA code of the station where the uplift happened.
        synonyms: ["station", "airport", "base"]
        sample_values: ["BYP", "DMM"]
      - name: airline_name
        expr: AIRLINE_NAME
        data_type: VARCHAR
        description: Airline customer / contract. Charter Operators (pooled) is the ad-hoc charter line.
        synonyms: ["airline", "carrier", "customer", "airline contract", "contract"]
        sample_values: ["Gulfway Airways", "Emirates", "flydubai", "Qatar Airways", "British Airways", "Charter Operators (pooled)"]
      - name: airline_code
        expr: AIRLINE_CODE
        data_type: VARCHAR
        description: IATA two-letter airline code (CHR = pooled charters).
        sample_values: ["GC", "EK", "FZ", "QR", "CHR"]
      - name: demo_alias
        expr: DEMO_ALIAS
        data_type: VARCHAR
        description: Anonymised carrier label used in committee material (Carrier A = Gulfway Airways, Carrier E = Emirates, Carrier F = flydubai, Carrier I = Charter).
        synonyms: ["carrier alias", "anonymised airline"]
        sample_values: ["Carrier A", "Carrier E", "Carrier F", "Carrier I"]
      - name: contract_type
        expr: CONTRACT_TYPE
        data_type: VARCHAR
        sample_values: ["Per Meal", "Per Meal + Turnaround", "Per Flight (ad hoc)"]
      - name: account_manager
        expr: ACCOUNT_MANAGER
        data_type: VARCHAR
        synonyms: ["AM", "key account manager"]
      - name: route_group
        expr: ROUTE_GROUP
        data_type: VARCHAR
        description: Destination region of the catered flights.
        synonyms: ["region", "route", "destination region", "sector"]
        sample_values: ["Europe", "GCC", "Asia", "MEA", "Charter"]
      - name: meal_class
        expr: MEAL_CLASS
        data_type: VARCHAR
        description: Cabin class code (F First, J Business, Y Economy).
        synonyms: ["class", "cabin"]
        sample_values: ["F", "J", "Y"]
      - name: meal_class_name
        expr: MEAL_CLASS_NAME
        data_type: VARCHAR
        sample_values: ["First", "Business", "Economy"]
      - name: menu_spec_code
        expr: MENU_SPEC_CODE
        data_type: VARCHAR
        description: Menu specification in force (airline-class-version). v3 specs started 1 Jul 2026 for Emirates, flydubai and Charter.
        synonyms: ["menu", "menu specification", "spec"]
        sample_values: ["EK-Y-v2", "EK-Y-v3", "GC-J-v2"]
      - name: spec_version
        expr: SPEC_VERSION
        data_type: NUMBER
        description: Menu specification version number; a higher version in a period indicates a spec change.
      - name: spec_change_reason
        expr: SPEC_CHANGE_REASON
        data_type: VARCHAR
        description: Why the menu spec changed.
        sample_values: ["Baseline contract specification", "Premium protein & dessert upgrade requested by airline"]
      - name: is_ramadan
        expr: IS_RAMADAN
        data_type: BOOLEAN
      - name: is_peak_season
        expr: IS_PEAK_SEASON
        data_type: BOOLEAN
    measures:
      - name: flights_catered
        expr: FLIGHTS_CATERED
        data_type: NUMBER
        default_aggregation: sum
        synonyms: ["catered flights"]
      - name: meals_planned
        expr: MEALS_PLANNED
        data_type: NUMBER
        default_aggregation: sum
      - name: meals_uplifted
        expr: MEALS_UPLIFTED
        data_type: NUMBER
        default_aggregation: sum
        description: Meals loaded on departing aircraft (certified measure M-005).
        synonyms: ["meals", "uplift", "meal volume", "meals served"]
      - name: meals_downlifted
        expr: MEALS_DOWNLIFTED
        data_type: NUMBER
        default_aggregation: sum
      - name: meals_wasted
        expr: MEALS_WASTED
        data_type: NUMBER
        default_aggregation: sum
        synonyms: ["wastage", "waste", "wasted meals"]
      - name: late_downlift_confirmations
        expr: LATE_DOWNLIFT_CONFIRMATIONS
        data_type: NUMBER
        default_aggregation: sum
        synonyms: ["late downlifts", "late confirmations"]
      - name: deliveries_total
        expr: DELIVERIES_TOTAL
        data_type: NUMBER
        default_aggregation: sum
      - name: deliveries_on_time
        expr: DELIVERIES_ON_TIME
        data_type: NUMBER
        default_aggregation: sum
      - name: food_cost_usd
        expr: FOOD_COST_USD
        data_type: NUMBER
        default_aggregation: sum
        synonyms: ["food cost", "raw material cost"]
      - name: labour_cost_usd
        expr: LABOUR_COST_USD
        data_type: NUMBER
        default_aggregation: sum
        synonyms: ["labour cost", "labor cost", "kitchen labour"]
      - name: overhead_cost_usd
        expr: OVERHEAD_COST_USD
        data_type: NUMBER
        default_aggregation: sum
      - name: total_cost_usd
        expr: TOTAL_COST_USD
        data_type: NUMBER
        default_aggregation: sum
        description: Food + labour + overhead cost of meals produced (USD).
        synonyms: ["catering cost", "production cost", "total cost"]
      - name: revenue_usd
        expr: REVENUE_USD
        data_type: NUMBER
        default_aggregation: sum
        synonyms: ["catering revenue", "billing", "sales"]
      - name: gross_margin_usd
        expr: GROSS_MARGIN_USD
        data_type: NUMBER
        default_aggregation: sum
        synonyms: ["catering margin", "gross margin"]
    metrics:
      - name: cost_per_meal
        description: Certified measure M-006. Total production cost divided by meals uplifted (USD per meal). Always recompute as a ratio of sums, never average the ratio.
        expr: SUM(catering_uplift.total_cost_usd) / NULLIF(SUM(catering_uplift.meals_uplifted), 0)
        synonyms: ["cost per meal uplifted", "unit meal cost", "CPM"]
      - name: food_cost_per_meal
        expr: SUM(catering_uplift.food_cost_usd) / NULLIF(SUM(catering_uplift.meals_uplifted), 0)
      - name: labour_cost_per_meal
        expr: SUM(catering_uplift.labour_cost_usd) / NULLIF(SUM(catering_uplift.meals_uplifted), 0)
      - name: wastage_pct
        description: Certified measure M-009. Meals wasted as % of meals uplifted; 4% is the alert threshold.
        expr: 100 * SUM(catering_uplift.meals_wasted) / NULLIF(SUM(catering_uplift.meals_uplifted), 0)
        synonyms: ["waste percentage", "wastage rate"]
      - name: on_time_catering_delivery_pct
        description: Certified measure M-010.
        expr: 100 * SUM(catering_uplift.deliveries_on_time) / NULLIF(SUM(catering_uplift.deliveries_total), 0)
        synonyms: ["on-time delivery", "OTD", "delivery punctuality"]
      - name: catering_margin_pct
        expr: 100 * SUM(catering_uplift.gross_margin_usd) / NULLIF(SUM(catering_uplift.revenue_usd), 0)
      - name: revenue_per_meal
        expr: SUM(catering_uplift.revenue_usd) / NULLIF(SUM(catering_uplift.meals_uplifted), 0)

  # ---------------------------------------------------------------- finance
  - name: finance_posting
    description: Monthly general-ledger actuals and budget by entity, cost centre, GL account and airline profit centre. Revenue is stored negative (SAP credit convention); use amount_presentation_usd for positive revenue and cost, pnl_contribution_usd for additive P&L.
    base_table:
      database: EDW_GOLD
      schema: SEMANTIC
      table: V_FINANCE_POSTING
    primary_key:
      columns: [FINANCE_POSTING_KEY]
    time_dimensions:
      - name: period_end_date
        expr: PERIOD_END_DATE
        data_type: DATE
        description: Last day of the fiscal month.
    dimensions:
      - name: finance_posting_key
        expr: FINANCE_POSTING_KEY
        data_type: NUMBER
        description: Surrogate row key (unique per row). Declared so it can serve as the table key.
        unique: true
      - name: fiscal_period
        expr: FISCAL_PERIOD
        data_type: VARCHAR
        synonyms: ["month", "period"]
        sample_values: ["2026-09"]
      - name: fiscal_quarter
        expr: FISCAL_QUARTER
        data_type: VARCHAR
        sample_values: ["FY26 Q3"]
      - name: fiscal_year
        expr: FISCAL_YEAR
        data_type: NUMBER
      - name: entity_code
        expr: ENTITY_CODE
        data_type: VARCHAR
        description: Legal entity (ASC, ASCD, ASCWF, ASCSA).
        synonyms: ["entity", "company", "legal entity", "subsidiary"]
        sample_values: ["ASC", "ASCD", "ASCWF", "ASCSA"]
      - name: entity_name
        expr: ENTITY_NAME
        data_type: VARCHAR
        sample_values: ["ASC B.S.C. (c)", "ASC Workforce Services W.L.L."]
      - name: business_unit
        expr: BUSINESS_UNIT
        data_type: VARCHAR
        synonyms: ["BU", "division", "line of business"]
        sample_values: ["Ground Handling", "Flight Catering", "Cargo", "Engineering", "Corporate", "Manpower", "Training & Development"]
      - name: cost_center_code
        expr: COST_CENTER_CODE
        data_type: VARCHAR
        synonyms: ["cost centre", "CC"]
      - name: cost_center_name
        expr: COST_CENTER_NAME
        data_type: VARCHAR
        sample_values: ["Catering Night Shift", "GH Ramp Operations - Day", "Manpower Pool - Ramp"]
      - name: station_code
        expr: STATION_CODE
        data_type: VARCHAR
        sample_values: ["BYP", "DMM", "RUH"]
      - name: gl_account
        expr: GL_ACCOUNT
        data_type: VARCHAR
        synonyms: ["account", "GL"]
      - name: gl_description
        expr: GL_DESCRIPTION
        data_type: VARCHAR
        sample_values: ["Catering Revenue - Airline Contracts", "Contractor Labour - Overtime", "GSE Fuel & Lubricants"]
      - name: account_class
        expr: ACCOUNT_CLASS
        data_type: VARCHAR
        description: Revenue, COGS, Opex or Below EBITDA.
        sample_values: ["Revenue", "COGS", "Opex", "Below EBITDA"]
      - name: kpi_group
        expr: KPI_GROUP
        data_type: VARCHAR
        synonyms: ["cost category", "cost type"]
        sample_values: ["Revenue", "Food Cost", "Direct Labour", "Contractor Cost", "Fuel", "Maintenance", "Facilities", "Depreciation"]
      - name: is_ebitda
        expr: IS_EBITDA
        data_type: BOOLEAN
        description: TRUE for accounts included in EBITDA.
      - name: is_intercompany
        expr: IS_INTERCOMPANY
        data_type: BOOLEAN
        description: TRUE for intercompany manpower billing (400500 / 510700); exclude for group figures.
      - name: airline_name
        expr: AIRLINE_NAME
        data_type: VARCHAR
        description: Airline profit centre on revenue postings (NULL on cost postings).
        synonyms: ["airline", "carrier", "profit centre"]
    measures:
      - name: amount_usd
        expr: AMOUNT_USD
        data_type: NUMBER
        default_aggregation: sum
        description: Signed GL amount (credit negative).
      - name: budget_usd
        expr: BUDGET_USD
        data_type: NUMBER
        default_aggregation: sum
      - name: variance_usd
        expr: VARIANCE_USD
        data_type: NUMBER
        default_aggregation: sum
        description: Actual minus budget (signed, same convention as amount_usd).
      - name: amount_presentation_usd
        expr: AMOUNT_PRESENTATION_USD
        data_type: NUMBER
        default_aggregation: sum
        description: Amount with natural sign (revenue positive, costs positive).
        synonyms: ["amount", "actual", "spend", "cost"]
      - name: budget_presentation_usd
        expr: BUDGET_PRESENTATION_USD
        data_type: NUMBER
        default_aggregation: sum
        synonyms: ["budget", "plan"]
      - name: pnl_contribution_usd
        expr: PNL_CONTRIBUTION_USD
        data_type: NUMBER
        default_aggregation: sum
        description: Additive P&L contribution (revenue positive, cost negative). SUM over is_ebitda rows = EBITDA.
    metrics:
      - name: revenue
        description: Certified measure M-001. External revenue, intercompany excluded.
        expr: SUM(CASE WHEN finance_posting.account_class = 'Revenue' AND NOT finance_posting.is_intercompany THEN finance_posting.pnl_contribution_usd ELSE 0 END)
        synonyms: ["turnover", "sales", "top line"]
      - name: ebitda
        description: Certified measure M-002.
        expr: SUM(CASE WHEN finance_posting.is_ebitda AND NOT finance_posting.is_intercompany THEN finance_posting.pnl_contribution_usd ELSE 0 END)
      - name: ebitda_margin_pct
        description: Certified measure M-003.
        expr: 100 * SUM(CASE WHEN finance_posting.is_ebitda AND NOT finance_posting.is_intercompany THEN finance_posting.pnl_contribution_usd ELSE 0 END) / NULLIF(SUM(CASE WHEN finance_posting.account_class = 'Revenue' AND NOT finance_posting.is_intercompany THEN finance_posting.pnl_contribution_usd ELSE 0 END), 0)
        synonyms: ["EBITDA %", "margin"]
      - name: contractor_spend
        expr: SUM(CASE WHEN finance_posting.kpi_group = 'Contractor Cost' AND NOT finance_posting.is_intercompany THEN finance_posting.amount_usd ELSE 0 END)
        synonyms: ["contractor cost", "agency spend", "manpower spend"]
      - name: contractor_spend_vs_budget_pct
        description: Certified measure M-029.
        expr: 100 * (SUM(CASE WHEN finance_posting.kpi_group = 'Contractor Cost' AND NOT finance_posting.is_intercompany THEN finance_posting.amount_usd ELSE 0 END) - SUM(CASE WHEN finance_posting.kpi_group = 'Contractor Cost' AND NOT finance_posting.is_intercompany THEN finance_posting.budget_usd ELSE 0 END)) / NULLIF(SUM(CASE WHEN finance_posting.kpi_group = 'Contractor Cost' AND NOT finance_posting.is_intercompany THEN finance_posting.budget_usd ELSE 0 END), 0)
      - name: budget_variance_pct
        expr: 100 * SUM(finance_posting.variance_usd) / NULLIF(ABS(SUM(finance_posting.budget_usd)), 0)

  # ---------------------------------------------------------------- airline P&L (monthly)
  - name: airline_pnl_monthly
    description: Monthly P&L per airline contract - catering and ground handling revenue, costs, contribution margin, cost per meal and modelled handling cost per flight (82% of handling revenue).
    base_table:
      database: EDW_GOLD
      schema: SEMANTIC
      table: V_AIRLINE_PNL_MONTHLY
    primary_key:
      columns: [fiscal_period, airline_code]
    dimensions:
      - name: fiscal_period
        expr: FISCAL_PERIOD
        data_type: VARCHAR
        synonyms: ["month"]
      - name: airline_name
        expr: AIRLINE_NAME
        data_type: VARCHAR
        synonyms: ["airline", "carrier", "contract"]
      - name: airline_code
        expr: AIRLINE_CODE
        data_type: VARCHAR
      - name: demo_alias
        expr: DEMO_ALIAS
        data_type: VARCHAR
      - name: contract_type
        expr: CONTRACT_TYPE
        data_type: VARCHAR
      - name: account_manager
        expr: ACCOUNT_MANAGER
        data_type: VARCHAR
    measures:
      - name: flights_handled
        expr: FLIGHTS_HANDLED
        data_type: NUMBER
        default_aggregation: sum
        synonyms: ["flights", "turnarounds", "flights serviced"]
      - name: meals_uplifted
        expr: MEALS_UPLIFTED
        data_type: NUMBER
        default_aggregation: sum
      - name: catering_revenue_usd
        expr: CATERING_REVENUE_USD
        data_type: NUMBER
        default_aggregation: sum
      - name: catering_cost_usd
        expr: CATERING_COST_USD
        data_type: NUMBER
        default_aggregation: sum
      - name: handling_revenue_usd
        expr: HANDLING_REVENUE_USD
        data_type: NUMBER
        default_aggregation: sum
        synonyms: ["ground handling revenue"]
      - name: handling_cost_usd
        expr: HANDLING_COST_USD
        data_type: NUMBER
        default_aggregation: sum
      - name: total_revenue_usd
        expr: TOTAL_REVENUE_USD
        data_type: NUMBER
        default_aggregation: sum
        description: Certified measure M-013 (revenue per airline).
        synonyms: ["revenue per airline", "airline revenue"]
      - name: contribution_margin_usd
        expr: CONTRIBUTION_MARGIN_USD
        data_type: NUMBER
        default_aggregation: sum
        description: Certified measure M-014.
        synonyms: ["margin per airline", "airline margin", "contribution"]
    metrics:
      - name: contribution_margin_pct
        description: Certified measure M-015.
        expr: 100 * SUM(airline_pnl_monthly.contribution_margin_usd) / NULLIF(SUM(airline_pnl_monthly.total_revenue_usd), 0)
      - name: airline_handling_cost_per_flight
        description: Modelled handling cost per flight for one airline contract. Handling cost here is a fixed 82% of that airline's handling revenue, not the actual ledger cost, so this is NOT measure M-017. For cost per flight serviced (group, company or all periods) use cost_per_flight_serviced.
        expr: SUM(airline_pnl_monthly.handling_cost_usd) / NULLIF(SUM(airline_pnl_monthly.flights_handled), 0)
        synonyms: ["airline handling cost per flight", "modelled cost per flight"]

  # ---------------------------------------------------------------- asset reliability
  - name: asset_reliability_monthly
    description: Monthly GSE asset reliability - operating hours, failures, hydraulic faults, downtime hours and cost, MTBF and MTTR, with rolling 3-month hydraulic fault count and 6-month downtime-cost baseline.
    base_table:
      database: EDW_GOLD
      schema: SEMANTIC
      table: V_ASSET_RELIABILITY_MONTHLY
    dimensions:
      - name: fiscal_period
        expr: FISCAL_PERIOD
        data_type: VARCHAR
        synonyms: ["month"]
      - name: asset_id
        expr: ASSET_ID
        data_type: VARCHAR
        description: GSE asset tag, e.g. T-114 is an aircraft pushback tug.
        synonyms: ["asset", "equipment", "tug", "GSE", "unit"]
        sample_values: ["T-114", "T-101", "HL-301", "CT-501", "GPU-401"]
      - name: asset_type
        expr: ASSET_TYPE
        data_type: VARCHAR
        sample_values: ["Aircraft Tug (Pushback)", "Belt Loader", "High Loader", "Ground Power Unit", "Catering Hi-Lift Truck"]
      - name: asset_class
        expr: ASSET_CLASS
        data_type: VARCHAR
      - name: make
        expr: MAKE
        data_type: VARCHAR
      - name: model
        expr: MODEL
        data_type: VARCHAR
      - name: station_code
        expr: STATION_CODE
        data_type: VARCHAR
      - name: cost_center_code
        expr: COST_CENTER_CODE
        data_type: VARCHAR
      - name: asset_status
        expr: ASSET_STATUS
        data_type: VARCHAR
        sample_values: ["Active", "Watch List - Hydraulic", "Under Major Overhaul"]
      - name: criticality
        expr: CRITICALITY
        data_type: VARCHAR
    measures:
      - name: operating_hours
        expr: OPERATING_HOURS
        data_type: NUMBER
        default_aggregation: sum
      - name: failures
        expr: FAILURES
        data_type: NUMBER
        default_aggregation: sum
        synonyms: ["breakdowns", "corrective work orders"]
      - name: hydraulic_faults
        expr: HYDRAULIC_FAULTS
        data_type: NUMBER
        default_aggregation: sum
        synonyms: ["HYD faults", "hydraulic failures", "hydraulic fault codes"]
      - name: repair_hours
        expr: REPAIR_HOURS
        data_type: NUMBER
        default_aggregation: sum
      - name: downtime_hours
        expr: DOWNTIME_HOURS
        data_type: NUMBER
        default_aggregation: sum
      - name: downtime_cost_usd
        expr: DOWNTIME_COST_USD
        data_type: NUMBER
        default_aggregation: sum
        description: Certified measure M-021.
        synonyms: ["downtime cost", "unavailability cost"]
      - name: hydraulic_faults_3m
        expr: HYDRAULIC_FAULTS_3M
        data_type: NUMBER
        default_aggregation: max
        description: Rolling 3-month hydraulic fault count (already windowed; use MAX, do not sum across months).
      - name: downtime_cost_6m_baseline
        expr: DOWNTIME_COST_6M_BASELINE
        data_type: NUMBER
        default_aggregation: avg
    metrics:
      - name: mtbf_hours
        description: Certified measure M-022. Operating hours per failure.
        expr: SUM(asset_reliability_monthly.operating_hours) / NULLIF(SUM(asset_reliability_monthly.failures), 0)
        synonyms: ["mean time between failures", "MTBF"]
      - name: mttr_hours
        description: Certified measure M-023. Repair hours per failure.
        expr: SUM(asset_reliability_monthly.repair_hours) / NULLIF(SUM(asset_reliability_monthly.failures), 0)
        synonyms: ["mean time to repair", "MTTR"]

  # ---------------------------------------------------------------- labour
  - name: labour_cost
    description: Monthly hours and cost by home cost centre, deployed cost centre, employment type (Permanent / Contractor) and shift pattern. Contractors belong to ASCWF pools and are deployed into ASC operational cost centres.
    base_table:
      database: EDW_GOLD
      schema: SEMANTIC
      table: V_LABOUR_COST
    primary_key:
      columns: [LABOUR_COST_KEY]
    dimensions:
      - name: labour_cost_key
        expr: LABOUR_COST_KEY
        data_type: NUMBER
        description: Surrogate row key (unique per row). Declared so it can serve as the table key.
        unique: true
      - name: fiscal_period
        expr: FISCAL_PERIOD
        data_type: VARCHAR
        synonyms: ["month"]
      - name: fiscal_quarter
        expr: FISCAL_QUARTER
        data_type: VARCHAR
      - name: entity_code
        expr: ENTITY_CODE
        data_type: VARCHAR
        description: Home entity of the workforce (ASCWF for all contractors).
        sample_values: ["ASC", "ASCWF", "ASCSA", "ASCD"]
      - name: cost_center_name
        expr: COST_CENTER_NAME
        data_type: VARCHAR
        synonyms: ["home cost centre", "pool"]
      - name: business_unit
        expr: BUSINESS_UNIT
        data_type: VARCHAR
      - name: deployed_cost_center_name
        expr: DEPLOYED_COST_CENTER_NAME
        data_type: VARCHAR
        description: Where contractors actually work (e.g. GH Ramp Operations - Night).
        synonyms: ["deployment", "deployed to"]
      - name: deployed_business_unit
        expr: DEPLOYED_BUSINESS_UNIT
        data_type: VARCHAR
      - name: employment_type
        expr: EMPLOYMENT_TYPE
        data_type: VARCHAR
        synonyms: ["worker type", "staff type"]
        sample_values: ["Permanent", "Contractor"]
      - name: shift_pattern
        expr: SHIFT_PATTERN
        data_type: VARCHAR
        synonyms: ["shift"]
        sample_values: ["Day", "Night", "Rotating"]
    measures:
      - name: headcount
        expr: HEADCOUNT
        data_type: NUMBER
        default_aggregation: sum
        description: Additive only within a single cost centre and month.
      - name: regular_hours
        expr: REGULAR_HOURS
        data_type: NUMBER
        default_aggregation: sum
      - name: overtime_hours
        expr: OVERTIME_HOURS
        data_type: NUMBER
        default_aggregation: sum
        description: Certified measure M-026.
        synonyms: ["OT hours", "overtime", "OT"]
      - name: night_hours
        expr: NIGHT_HOURS
        data_type: NUMBER
        default_aggregation: sum
      - name: regular_cost_usd
        expr: REGULAR_COST_USD
        data_type: NUMBER
        default_aggregation: sum
      - name: overtime_cost_usd
        expr: OVERTIME_COST_USD
        data_type: NUMBER
        default_aggregation: sum
        synonyms: ["OT cost"]
      - name: total_cost_usd
        expr: TOTAL_COST_USD
        data_type: NUMBER
        default_aggregation: sum
        synonyms: ["labour cost", "payroll cost", "people cost"]
    metrics:
      - name: overtime_ratio_pct
        description: Certified measure M-027. Overtime hours as % of total paid hours.
        expr: 100 * SUM(labour_cost.overtime_hours) / NULLIF(SUM(labour_cost.regular_hours) + SUM(labour_cost.overtime_hours), 0)
        synonyms: ["OT ratio", "overtime percentage"]

  # ---------------------------------------------------------------- airline orders / SLA
  - name: airline_order
    description: Daily airline portal activity per airline - orders, amendments after cut-off, special meals, SLA events and breaches.
    base_table:
      database: EDW_GOLD
      schema: SEMANTIC
      table: V_AIRLINE_ORDER
    primary_key:
      columns: [AIRLINE_ORDER_KEY]
    time_dimensions:
      - name: order_date
        expr: ORDER_DATE
        data_type: DATE
    dimensions:
      - name: airline_order_key
        expr: AIRLINE_ORDER_KEY
        data_type: NUMBER
        description: Surrogate row key (unique per row). Declared so it can serve as the table key.
        unique: true
      - name: fiscal_period
        expr: FISCAL_PERIOD
        data_type: VARCHAR
      - name: fiscal_quarter
        expr: FISCAL_QUARTER
        data_type: VARCHAR
      - name: airline_name
        expr: AIRLINE_NAME
        data_type: VARCHAR
        synonyms: ["airline", "carrier"]
      - name: demo_alias
        expr: DEMO_ALIAS
        data_type: VARCHAR
    measures:
      - name: orders_submitted
        expr: ORDERS_SUBMITTED
        data_type: NUMBER
        default_aggregation: sum
      - name: orders_amended_after_cutoff
        expr: ORDERS_AMENDED_AFTER_CUTOFF
        data_type: NUMBER
        default_aggregation: sum
        synonyms: ["late amendments", "changes after cut-off"]
      - name: special_meal_orders
        expr: SPECIAL_MEAL_ORDERS
        data_type: NUMBER
        default_aggregation: sum
        synonyms: ["SPML"]
      - name: special_meals_unfulfilled
        expr: SPECIAL_MEALS_UNFULFILLED
        data_type: NUMBER
        default_aggregation: sum
      - name: sla_events
        expr: SLA_EVENTS
        data_type: NUMBER
        default_aggregation: sum
      - name: sla_breaches
        expr: SLA_BREACHES
        data_type: NUMBER
        default_aggregation: sum
        synonyms: ["breaches", "SLA failures"]
      - name: avg_order_lead_hours
        expr: AVG_ORDER_LEAD_HOURS
        data_type: NUMBER
        default_aggregation: avg
    metrics:
      - name: sla_compliance_pct
        description: Certified measure M-019.
        expr: 100 * (SUM(airline_order.sla_events) - SUM(airline_order.sla_breaches)) / NULLIF(SUM(airline_order.sla_events), 0)
        synonyms: ["SLA %", "SLA adherence", "service level compliance"]
      - name: spml_fulfilment_pct
        expr: 100 * (SUM(airline_order.special_meal_orders) - SUM(airline_order.special_meals_unfulfilled)) / NULLIF(SUM(airline_order.special_meal_orders), 0)

  # ---------------------------------------------------------------- KPI scorecard
  - name: kpi_monthly
    description: Pre-computed certified KPI scorecard at month x entity grain. Use for direct KPI questions (EBITDA margin, cost per meal, cost per flight, wastage %, SLA %, MTBF, MTTR, overtime ratio, contractor spend vs budget).
    base_table:
      database: EDW_GOLD
      schema: SEMANTIC
      table: V_KPI_MONTHLY
    primary_key:
      columns: [fiscal_period, entity_code]
    dimensions:
      - name: fiscal_period
        expr: FISCAL_PERIOD
        data_type: VARCHAR
        synonyms: ["month"]
      - name: entity_code
        expr: ENTITY_CODE
        data_type: VARCHAR
        sample_values: ["ASC", "ASCD", "ASCWF", "ASCSA"]
    measures:
      - name: revenue_usd
        expr: REVENUE_USD
        data_type: NUMBER
        default_aggregation: sum
      - name: ebitda_usd
        expr: EBITDA_USD
        data_type: NUMBER
        default_aggregation: sum
      - name: ebitda_margin_pct
        expr: EBITDA_MARGIN_PCT
        data_type: NUMBER
        default_aggregation: avg
        description: Pre-computed per entity-month; for multi-month figures recompute from ebitda_usd / revenue_usd.
      - name: cost_per_meal_usd
        expr: COST_PER_MEAL_USD
        data_type: NUMBER
        default_aggregation: avg
      - name: wastage_pct
        expr: WASTAGE_PCT
        data_type: NUMBER
        default_aggregation: avg
      - name: on_time_catering_delivery_pct
        expr: ON_TIME_CATERING_DELIVERY_PCT
        data_type: NUMBER
        default_aggregation: avg
      - name: flights_handled
        expr: FLIGHTS_HANDLED
        data_type: NUMBER
        default_aggregation: sum
      - name: cost_per_flight_serviced_usd
        expr: COST_PER_FLIGHT_SERVICED_USD
        data_type: NUMBER
        default_aggregation: avg
        synonyms: ["cost per flight", "cost per turnaround"]
      - name: on_time_departure_pct
        expr: ON_TIME_DEPARTURE_PCT
        data_type: NUMBER
        default_aggregation: avg
      - name: sla_compliance_pct
        expr: SLA_COMPLIANCE_PCT
        data_type: NUMBER
        default_aggregation: avg
      - name: asset_downtime_cost_usd
        expr: ASSET_DOWNTIME_COST_USD
        data_type: NUMBER
        default_aggregation: sum
      - name: mtbf_hours
        expr: MTBF_HOURS
        data_type: NUMBER
        default_aggregation: avg
      - name: mttr_hours
        expr: MTTR_HOURS
        data_type: NUMBER
        default_aggregation: avg
      - name: overtime_ratio_pct
        expr: OVERTIME_RATIO_PCT
        data_type: NUMBER
        default_aggregation: avg
      - name: contractor_ot_hours
        expr: CONTRACTOR_OT_HOURS
        data_type: NUMBER
        default_aggregation: sum
      - name: contractor_spend_usd
        expr: CONTRACTOR_SPEND_USD
        data_type: NUMBER
        default_aggregation: sum
      - name: contractor_spend_vs_budget_pct
        expr: CONTRACTOR_SPEND_VS_BUDGET_PCT
        data_type: NUMBER
        default_aggregation: avg
    metrics:
      - name: cost_per_flight_serviced
        description: Certified measure M-017. Actual Ground Handling cost from the finance ledger divided by flights handled, that is total cost over total flights for any months and companies selected, never an average of monthly ratios. Use for cost per flight, cost per flight serviced and ground handling cost per flight.
        expr: SUM(kpi_monthly.cost_per_flight_serviced_usd * kpi_monthly.flights_handled) / NULLIF(SUM(kpi_monthly.flights_handled), 0)
        synonyms: ["cost per flight", "cost per flight serviced", "ground handling cost per flight", "cost per turnaround"]

relationships:
  - name: catering_to_airline_pnl
    left_table: catering_uplift
    right_table: airline_pnl_monthly
    relationship_columns:
      - left_column: fiscal_period
        right_column: fiscal_period
      - left_column: airline_code
        right_column: airline_code
    join_type: left_outer
    relationship_type: many_to_one
  - name: finance_to_kpi
    left_table: finance_posting
    right_table: kpi_monthly
    relationship_columns:
      - left_column: fiscal_period
        right_column: fiscal_period
      - left_column: entity_code
        right_column: entity_code
    join_type: left_outer
    relationship_type: many_to_one

custom_instructions: >
  Currency is USD; format money with thousands separators and 0 decimals unless the question is about a unit cost
  (cost per meal: 3 decimals). "Last quarter" relative to the current date (Oct 2026) is FY26 Q3 = Jul, Aug, Sep 2026;
  compare it with FY26 Q2 (Apr-Jun 2026) unless another baseline is requested. Always compute ratios as ratio of sums.
  When asked "why" about cost per meal, decompose into food cost per meal, labour cost per meal, wastage % and late
  downlift confirmations, and mention the menu specification version in force. Exclude intercompany accounts from
  group revenue and EBITDA. Never list employee names or salaries; those are governed by masking policies.

verified_queries:
  - name: highest_cost_per_meal_last_quarter_and_why
    question: Which airline contracts had the highest cost per meal last quarter, and why?
    use_as_onboarding_question: true
    verified_by: Group Finance Data Steward
    verified_at: 1760486400
    sql: |
      WITH q AS (
        SELECT airline_name, demo_alias, fiscal_quarter,
               SUM(total_cost_usd) / NULLIF(SUM(meals_uplifted), 0)  AS cost_per_meal,
               SUM(food_cost_usd) / NULLIF(SUM(meals_uplifted), 0)   AS food_per_meal,
               SUM(labour_cost_usd) / NULLIF(SUM(meals_uplifted), 0) AS labour_per_meal,
               100 * SUM(meals_wasted) / NULLIF(SUM(meals_uplifted), 0) AS wastage_pct,
               SUM(late_downlift_confirmations) AS late_downlifts,
               MAX(spec_version) AS menu_spec_version
        FROM __catering_uplift
        WHERE fiscal_quarter IN ('FY26 Q2', 'FY26 Q3')
        GROUP BY 1, 2, 3
      )
      SELECT c.airline_name, c.demo_alias,
             ROUND(c.cost_per_meal, 3)   AS cost_per_meal_q3,
             ROUND(p.cost_per_meal, 3)   AS cost_per_meal_q2,
             ROUND(100 * (c.cost_per_meal / p.cost_per_meal - 1), 1) AS change_pct,
             ROUND(c.food_per_meal - p.food_per_meal, 3)     AS food_per_meal_delta,
             ROUND(c.labour_per_meal - p.labour_per_meal, 3) AS labour_per_meal_delta,
             ROUND(c.wastage_pct, 2) AS wastage_pct_q3, ROUND(p.wastage_pct, 2) AS wastage_pct_q2,
             c.late_downlifts AS late_downlifts_q3, p.late_downlifts AS late_downlifts_q2,
             c.menu_spec_version
      FROM q c JOIN q p ON p.airline_name = c.airline_name AND p.fiscal_quarter = 'FY26 Q2'
      WHERE c.fiscal_quarter = 'FY26 Q3'
      ORDER BY cost_per_meal_q3 DESC

  - name: ebitda_margin_by_entity_ytd
    question: What is the EBITDA margin by entity year to date?
    use_as_onboarding_question: true
    verified_by: Group Finance Data Steward
    verified_at: 1760486400
    sql: |
      SELECT entity_code,
             SUM(CASE WHEN account_class = 'Revenue' AND NOT is_intercompany THEN pnl_contribution_usd ELSE 0 END) AS revenue_usd,
             SUM(CASE WHEN is_ebitda AND NOT is_intercompany THEN pnl_contribution_usd ELSE 0 END) AS ebitda_usd,
             ROUND(100 * SUM(CASE WHEN is_ebitda AND NOT is_intercompany THEN pnl_contribution_usd ELSE 0 END)
                       / NULLIF(SUM(CASE WHEN account_class = 'Revenue' AND NOT is_intercompany THEN pnl_contribution_usd ELSE 0 END), 0), 2) AS ebitda_margin_pct
      FROM __finance_posting
      WHERE fiscal_year = 2026
      GROUP BY 1 ORDER BY revenue_usd DESC

  - name: tug_t114_downtime_trend
    question: Show the downtime cost and hydraulic fault trend for tug T-114 over the last 12 months. Is it getting worse?
    use_as_onboarding_question: true
    verified_by: Engineering Data Steward
    verified_at: 1760486400
    sql: |
      SELECT fiscal_period, asset_status, failures, hydraulic_faults, hydraulic_faults_3m, downtime_hours, downtime_cost_usd,
             ROUND(downtime_cost_6m_baseline, 2) AS downtime_cost_6m_baseline,
             ROUND(downtime_cost_usd / NULLIF(downtime_cost_6m_baseline, 0), 2) AS vs_baseline_x,
             ROUND(operating_hours / NULLIF(failures, 0), 1) AS mtbf_hours, ROUND(repair_hours / NULLIF(failures, 0), 1) AS mttr_hours
      FROM __asset_reliability_monthly
      WHERE asset_id = 'T-114' AND fiscal_period >= '2025-10'
      ORDER BY fiscal_period

  - name: contractor_overtime_spike_sep_2026
    question: How much did contractor overtime at ASCWF change in September 2026 versus August, and which deployments drove it?
    verified_by: HR Data Steward
    verified_at: 1760486400
    sql: |
      SELECT deployed_cost_center_name,
             SUM(CASE WHEN fiscal_period = '2026-08' THEN overtime_hours ELSE 0 END) AS ot_hours_aug,
             SUM(CASE WHEN fiscal_period = '2026-09' THEN overtime_hours ELSE 0 END) AS ot_hours_sep,
             SUM(CASE WHEN fiscal_period = '2026-09' THEN overtime_hours ELSE 0 END) - SUM(CASE WHEN fiscal_period = '2026-08' THEN overtime_hours ELSE 0 END) AS delta_hours,
             SUM(CASE WHEN fiscal_period = '2026-09' THEN overtime_cost_usd ELSE 0 END) - SUM(CASE WHEN fiscal_period = '2026-08' THEN overtime_cost_usd ELSE 0 END) AS delta_cost_usd
      FROM __labour_cost
      WHERE entity_code = 'ASCWF' AND employment_type = 'Contractor' AND fiscal_period IN ('2026-08', '2026-09')
      GROUP BY 1 ORDER BY delta_hours DESC

  - name: wastage_above_threshold_by_route_group
    question: Which route groups had wastage above 4% in September 2026?
    verified_by: Catering Data Steward
    verified_at: 1760486400
    sql: |
      SELECT airline_name, route_group,
             SUM(meals_uplifted) AS meals_uplifted, SUM(meals_wasted) AS meals_wasted,
             ROUND(100 * SUM(meals_wasted) / NULLIF(SUM(meals_uplifted), 0), 2) AS wastage_pct
      FROM __catering_uplift
      WHERE fiscal_period = '2026-09'
      GROUP BY 1, 2
      HAVING 100 * SUM(meals_wasted) / NULLIF(SUM(meals_uplifted), 0) > 4
      ORDER BY wastage_pct DESC

  - name: revenue_and_margin_per_airline_q3
    question: Rank airlines by revenue and contribution margin for FY26 Q3.
    verified_by: Commercial Data Steward
    verified_at: 1760486400
    sql: |
      SELECT airline_name, demo_alias,
             SUM(total_revenue_usd) AS revenue_usd, SUM(contribution_margin_usd) AS margin_usd,
             ROUND(100 * SUM(contribution_margin_usd) / NULLIF(SUM(total_revenue_usd), 0), 2) AS margin_pct,
             SUM(meals_uplifted) AS meals_uplifted, SUM(flights_handled) AS flights_handled,
             ROUND(SUM(catering_cost_usd) / NULLIF(SUM(meals_uplifted), 0), 3) AS cost_per_meal
      FROM __airline_pnl_monthly
      WHERE fiscal_period IN ('2026-07', '2026-08', '2026-09')
      GROUP BY 1, 2 ORDER BY revenue_usd DESC

  - name: sla_compliance_trend_story_airlines
    question: What was SLA compliance for Emirates, flydubai and Charter by month in 2026?
    verified_by: Commercial Data Steward
    verified_at: 1760486400
    sql: |
      SELECT fiscal_period, airline_name,
             SUM(sla_events) AS sla_events, SUM(sla_breaches) AS sla_breaches,
             ROUND(100 * (SUM(sla_events) - SUM(sla_breaches)) / NULLIF(SUM(sla_events), 0), 2) AS sla_compliance_pct,
             SUM(orders_amended_after_cutoff) AS late_amendments
      FROM __airline_order
      WHERE fiscal_period >= '2026-01' AND airline_name IN ('Emirates', 'flydubai', 'Charter Operators (pooled)')
      GROUP BY 1, 2 ORDER BY 1, 2

  - name: cost_per_flight_serviced_trend
    question: How has cost per flight serviced trended by month for ASC in 2026?
    verified_by: Operations Data Steward
    verified_at: 1760486400
    sql: |
      SELECT fiscal_period, flights_handled, cost_per_flight_serviced_usd, on_time_departure_pct
      FROM __kpi_monthly
      WHERE entity_code = 'ASC' AND fiscal_period >= '2026-01'
      ORDER BY fiscal_period
$$, FALSE);

GRANT SELECT ON SEMANTIC VIEW EDW_GOLD.SEMANTIC.GROUP_PERFORMANCE TO ROLE ROLE_GROUP_EXEC;
GRANT SELECT ON SEMANTIC VIEW EDW_GOLD.SEMANTIC.GROUP_PERFORMANCE TO ROLE ROLE_FIN_ASC;
GRANT SELECT ON SEMANTIC VIEW EDW_GOLD.SEMANTIC.GROUP_PERFORMANCE TO ROLE ROLE_AIRLINE_AM;
GRANT SELECT ON SEMANTIC VIEW EDW_GOLD.SEMANTIC.GROUP_PERFORMANCE TO ROLE ROLE_INTERNAL_AUDIT;
