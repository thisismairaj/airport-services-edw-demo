"""SQL for the Airline P&L, GSE reliability, People and contractors and Governance pages.
Each function mirrors the DAX measures in ../powerbi/measures.dax named in its docstring."""
from queries_ops import A, C, S, dims, in_list, q

# ---------------------------------------------------------------- 4. Airline P&L (AGG_MONTHLY_AIRLINE_PNL)
MANAGERS = f"SELECT DISTINCT account_manager FROM {S}DIM_AIRLINE ORDER BY 1"
PNL_YEARS = f"SELECT DISTINCT LEFT(fiscal_period, 4)::INT AS fiscal_year FROM {A}AGG_MONTHLY_AIRLINE_PNL ORDER BY 1"
PNL = (f"{A}AGG_MONTHLY_AIRLINE_PNL p JOIN {S}DIM_AIRLINE a ON a.airline_key = p.airline_key "
       f"JOIN (SELECT DISTINCT fiscal_period, fiscal_quarter FROM {S}DIM_DATE) pq ON pq.fiscal_period = p.fiscal_period")
REV_MARGIN = ("SUM(p.total_revenue_usd) AS revenue, "
              "SUM(p.contribution_margin_usd) / NULLIF(SUM(p.total_revenue_usd), 0) AS margin")   # M-013, M-015


def pnl_where(managers, years, manager=None):
    yrs = in_list("LEFT(p.fiscal_period, 4)", [str(int(y)) for y in years])
    return f"{in_list('a.account_manager', managers)} AND {yrs} AND {f'a.account_manager = {q(manager)}' if manager else 'TRUE'}"


def pnl_by(level, managers, years, manager=None):
    """Revenue and margin % by account manager, or (manager given) by airline of that manager."""
    col = "a.account_manager" if level == "manager" else "a.airline_name"
    return f"SELECT {col} AS item, {REV_MARGIN} FROM {PNL} WHERE {pnl_where(managers, years, manager)} GROUP BY 1"


def pnl_monthly(managers):
    """Revenue per Airline and Margin per Airline per fiscal month, for the cards' trend and year-on-year change."""
    return f"""
SELECT p.fiscal_period, SUM(p.total_revenue_usd) AS revenue, SUM(p.contribution_margin_usd) AS margin_usd
FROM {PNL} WHERE {pnl_where(managers, [])} GROUP BY 1 ORDER BY 1"""


def pnl_trend(grain, managers, years, quarter=None):
    """Airline revenue by quarter, or by month within one quarter."""
    label = "pq.fiscal_quarter" if grain == "Quarter" else "p.fiscal_period"
    within = f"pq.fiscal_quarter = {q(quarter)}" if quarter else "TRUE"
    return f"""
SELECT {label} AS period_label, MIN(p.fiscal_period) AS period_sort, SUM(p.total_revenue_usd) AS revenue
FROM {PNL} WHERE {pnl_where(managers, years)} AND {within} GROUP BY 1"""


# ---------------------------------------------------------------- 5. GSE reliability (one asset, e.g. tug T-114)
ASSETS = f"SELECT DISTINCT asset_id FROM {S}DIM_ASSET ORDER BY 1"


def asset_months(asset):
    """Asset Downtime Cost, Downtime Cost 6M Baseline (average of the six months before), Hydraulic Faults and
    Hydraulic Faults 3M (rolling three months) per month. Blank, not zero, where there is nothing, as in DAX."""
    return f"""
WITH m AS (SELECT fiscal_period, MIN(calendar_date) AS ms FROM {S}DIM_DATE GROUP BY 1),
w AS (SELECT DATE_TRUNC(month, d.calendar_date) AS ms, SUM(o.downtime_cost_usd) AS cost,
             NULLIF(COUNT_IF(o.is_failure AND LEFT(o.fault_code, 3) = 'HYD'), 0) AS hyd
      FROM {S}FACT_WORK_ORDER o JOIN {S}DIM_DATE d ON d.date_key = o.date_key WHERE o.asset_id = {q(asset)} GROUP BY 1),
base AS (SELECT m.ms, SUM(b.cost) / 6 AS baseline FROM m LEFT JOIN w b
         ON b.ms BETWEEN DATEADD(month, -6, m.ms) AND DATEADD(month, -1, m.ms) GROUP BY 1),
h3 AS (SELECT m.ms, NULLIF(SUM(b.hyd), 0) AS hyd_3m FROM m LEFT JOIN w b ON b.ms BETWEEN DATEADD(month, -2, m.ms) AND m.ms GROUP BY 1)
SELECT m.fiscal_period AS period_label, m.ms AS period_sort, w.cost, base.baseline, w.hyd, h3.hyd_3m
FROM m JOIN base ON base.ms = m.ms JOIN h3 ON h3.ms = m.ms LEFT JOIN w ON w.ms = m.ms ORDER BY m.ms"""


def asset_versions(asset):
    return f"""
SELECT asset_id, version_no, status, effective_from, effective_to FROM {S}DIM_ASSET
WHERE asset_id = {q(asset)} ORDER BY version_no"""


def asset_reliability(asset):
    """Operating Hours, MTBF Hours and MTTR Hours by month, with a total row."""
    calc = ("SUM(operating_hours) AS operating_hours, SUM(operating_hours) / NULLIF(SUM(failures), 0) AS mtbf, "
            "SUM(repair_hours) / NULLIF(SUM(failures), 0) AS mttr")
    t = f"{A}AGG_MONTHLY_ASSET_RELIABILITY WHERE asset_id = {q(asset)}"
    return f"""
SELECT fiscal_period, {calc} FROM {t} GROUP BY 1
UNION ALL SELECT 'Total', {calc} FROM {t} ORDER BY 1"""


# ---------------------------------------------------------------- 6. People and contractors
CONTRACTOR_OT = f"""
WITH t AS (SELECT d.fiscal_period, DATE_TRUNC(month, MIN(d.calendar_date)) AS ms,
                  SUM(IFF(l.employment_type = 'Contractor', l.overtime_hours, NULL)) AS ot
           FROM {S}FACT_LABOUR_COST l JOIN {S}DIM_DATE d ON d.date_key = l.date_key GROUP BY 1)
SELECT t.fiscal_period AS period_label, t.ms AS period_sort, t.ot AS contractor_ot,
       IFF(p.ot IS NULL, NULL, COALESCE(t.ot, 0) - p.ot) AS delta_vs_pm
FROM t LEFT JOIN t p ON p.ms = DATEADD(month, -1, t.ms)"""
# Contractor OT Hours and Contractor OT Δ vs PM (hrs): blank for a month with no previous month.


def overtime_ratio_by(entity=None):
    """Overtime Ratio % by company, or (entity given) by shift pattern within that company."""
    col = "l.shift_pattern" if entity else "e.entity_code"
    return f"""
SELECT {col} AS item, SUM(l.overtime_hours) / NULLIF(SUM(l.regular_hours) + SUM(l.overtime_hours), 0) AS ot_ratio
FROM {S}FACT_LABOUR_COST l {dims('l')} WHERE {f'e.entity_code = {q(entity)}' if entity else 'TRUE'} GROUP BY 1"""


PEOPLE_MONTHLY = f"""
WITH c AS (SELECT d.fiscal_period, SUM(f.amount_usd) AS contractor_spend, SUM(f.budget_usd) AS contractor_budget
           FROM {S}FACT_FINANCE_POSTING f JOIN {S}DIM_GL_ACCOUNT g ON g.gl_account_key = f.gl_account_key
           JOIN {S}DIM_DATE d ON d.date_key = f.date_key
           WHERE g.kpi_group = 'Contractor Cost' AND NOT g.is_intercompany GROUP BY 1),
l AS (SELECT d.fiscal_period, SUM(l.total_cost_usd) AS labour_cost, SUM(l.overtime_hours) AS ot_hours,
             SUM(l.regular_hours + l.overtime_hours) AS all_hours
      FROM {S}FACT_LABOUR_COST l JOIN {S}DIM_DATE d ON d.date_key = l.date_key GROUP BY 1)
SELECT * FROM l LEFT JOIN c USING (fiscal_period) ORDER BY fiscal_period"""
# Per fiscal month: contractor spend and budget, labour cost, overtime and all hours (the People cards' parts)

ACTIVE_EMPLOYEES = f"SELECT COUNT_IF(employment_status = 'Active') AS active FROM {S}DIM_EMPLOYEE"

# ---------------------------------------------------------------- 7. Governance
GOVERNANCE_CARDS = f"""
SELECT COUNT_IF(r.status = 'PASS') / NULLIF(COUNT_IF(r.status <> 'INFO'), 0) AS recon_passed,
       (SELECT MAX(certified_at) FROM {C}CERTIFICATION_LOG) AS certified_at,
       (SELECT COUNT(DISTINCT vendor_key) FROM {S}FACT_PURCHASE_ORDER) AS golden_vendors,
       (SELECT COUNT(DISTINCT source_vendor_id) FROM {S}FACT_PURCHASE_ORDER) AS source_vendor_ids
FROM {C}RECON_RESULTS r WHERE r.run_id = (SELECT MAX(run_id) FROM {C}RECON_RESULTS)"""
# Recon Checks Passed % (M-032, latest run), Data Certified As Of, Golden Vendors, Source Vendor Ids.

RECON = f"""
SELECT check_name, src_system, source_value, target_value, variance, status FROM {C}RECON_RESULTS
WHERE run_id = (SELECT MAX(run_id) FROM {C}RECON_RESULTS) ORDER BY check_name"""

CATALOG = f"SELECT measure_id, measure_name, kpi_family, owner, certified FROM {C}MEASURE_CATALOG ORDER BY measure_id"
