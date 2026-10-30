"""SQL for the Group scorecard, Catering cost per meal and Wastage by route group pages.
Each function mirrors the DAX measures in ../powerbi/measures.dax named in its docstring: every ratio is
a ratio of sums, revenue is flipped with DIM_GL_ACCOUNT.natural_sign, intercompany is excluded.
Periods: grain 'Quarter' (fiscal_quarter, e.g. FY26 Q3) or 'Month' (fiscal_period, e.g. 2026-09);
quarter = a fiscal quarter to drill into (its months)."""

S = "EDW_GOLD.STAR."
A = "EDW_GOLD.AGG."
C = "EDW_GOLD.CONTROL."


def q(v):
    """Quote a value for SQL. Values only ever come from the app's own option lists."""
    return "'" + str(v).replace("'", "''") + "'"


def in_list(col, values):
    return f"{col} IN ({', '.join(q(v) for v in values)})" if values else "TRUE"


def period(grain):
    return "d.fiscal_quarter" if grain == "Quarter" else "d.fiscal_period"


def where(years=(), entities=(), quarter=None, airlines=()):
    """Filters on DIM_DATE d, DIM_ENTITY e and DIM_AIRLINE a (join only what is filtered)."""
    parts = [in_list("d.fiscal_year", [int(y) for y in years]) if years else "TRUE", in_list("e.entity_code", entities),
             f"d.fiscal_quarter = {q(quarter)}" if quarter else "TRUE", in_list("a.airline_name", airlines)]
    return " AND ".join(p for p in parts if p != "TRUE") or "TRUE"


def dims(alias, airline=False):
    j = f"JOIN {S}DIM_DATE d ON d.date_key = {alias}.date_key JOIN {S}DIM_ENTITY e ON e.entity_key = {alias}.entity_key"
    return j + (f" JOIN {S}DIM_AIRLINE a ON a.airline_key = {alias}.airline_key" if airline else "")


FIN = (f"{S}FACT_FINANCE_POSTING f JOIN {S}DIM_GL_ACCOUNT g ON g.gl_account_key = f.gl_account_key "
       f"LEFT JOIN {S}DIM_COST_CENTER c ON c.cost_center_key = f.cost_center_key {dims('f')}")
REVENUE = "SUM(IFF(g.account_class = 'Revenue' AND NOT g.is_intercompany, f.amount_usd * g.natural_sign, 0))"   # M-001
EBITDA = "SUM(IFF(g.is_ebitda AND NOT g.is_intercompany, -f.amount_usd, 0))"                                     # M-002
GH_COST = ("SUM(IFF(c.business_unit = 'Ground Handling' AND g.account_class IN ('COGS', 'Opex') "
           "AND NOT g.is_intercompany, f.amount_usd, 0))")                                                        # M-017 numerator


# ---------------------------------------------------------------- 1. Group scorecard
def scorecard_monthly(entities):
    """Per fiscal month, the parts of the scorecard KPIs (summed, so any set of months can be totalled and the
    ratios taken afterwards): Revenue and EBITDA with their budgets, Cost per Meal, Cost per Flight Serviced,
    SLA Compliance %, Wastage %, Overtime Ratio %."""
    w = where(entities=entities)
    rev_budget = REVENUE.replace("f.amount_usd", "f.budget_usd")
    ebitda_budget = EBITDA.replace("f.amount_usd", "f.budget_usd")
    return f"""
WITH fin AS (SELECT d.fiscal_period, {REVENUE} AS revenue, {rev_budget} AS revenue_budget, {EBITDA} AS ebitda,
                    {ebitda_budget} AS ebitda_budget, {GH_COST} AS gh_cost FROM {FIN} WHERE {w} GROUP BY 1),
cat AS (SELECT d.fiscal_period, SUM(u.total_cost_usd) AS catering_cost, SUM(u.meals_uplifted) AS meals,
               SUM(u.meals_wasted) AS wasted FROM {S}FACT_CATERING_UPLIFT u {dims('u')} WHERE {w} GROUP BY 1),
fl AS (SELECT d.fiscal_period, SUM(x.flights_handled) AS flights FROM {A}AGG_DAILY_FLIGHTS x {dims('x')} WHERE {w} GROUP BY 1),
sla AS (SELECT d.fiscal_period, SUM(o.sla_events) AS sla_events, SUM(o.sla_events - o.sla_breaches) AS sla_met
        FROM {S}FACT_AIRLINE_ORDER o {dims('o')} WHERE {w} GROUP BY 1),
lab AS (SELECT d.fiscal_period, SUM(l.overtime_hours) AS ot_hours, SUM(l.regular_hours + l.overtime_hours) AS all_hours
        FROM {S}FACT_LABOUR_COST l {dims('l')} WHERE {w} GROUP BY 1),
m AS (SELECT fiscal_period FROM fin UNION SELECT fiscal_period FROM cat UNION SELECT fiscal_period FROM lab)
SELECT * FROM m LEFT JOIN fin USING (fiscal_period) LEFT JOIN cat USING (fiscal_period) LEFT JOIN fl USING (fiscal_period)
LEFT JOIN sla USING (fiscal_period) LEFT JOIN lab USING (fiscal_period) ORDER BY fiscal_period"""


def revenue_ebitda(grain, years, entities, quarter=None):
    return f"""
SELECT {period(grain)} AS period_label, MIN(d.calendar_date) AS period_sort, {REVENUE} AS revenue, {EBITDA} AS ebitda
FROM {FIN} WHERE {where(years, entities, quarter)} GROUP BY 1"""


def cost_per_meal_trend(grain, years, entities, quarter=None):
    return f"""
SELECT {period(grain)} AS period_label, MIN(d.calendar_date) AS period_sort,
       SUM(u.total_cost_usd) / NULLIF(SUM(u.meals_uplifted), 0) AS cost_per_meal
FROM {S}FACT_CATERING_UPLIFT u {dims('u')} WHERE {where(years, entities, quarter)} GROUP BY 1"""


CERTIFICATION = f"""
SELECT (SELECT MAX(certified_at) FROM {C}CERTIFICATION_LOG) AS certified_at,
       COUNT_IF(status = 'PASS') / NULLIF(COUNT_IF(status <> 'INFO'), 0) AS recon_passed
FROM {C}RECON_RESULTS WHERE run_id = (SELECT MAX(run_id) FROM {C}RECON_RESULTS)"""


# ---------------------------------------------------------------- 2. Catering cost per meal
COST_BY_AIRLINE_QUARTER = f"""
WITH t AS (
  SELECT a.airline_name, d.fiscal_quarter, DATE_TRUNC(quarter, MIN(d.calendar_date)) AS qs,
         SUM(u.total_cost_usd) / NULLIF(SUM(u.meals_uplifted), 0) AS cpm
  FROM {S}FACT_CATERING_UPLIFT u {dims('u', airline=True)} GROUP BY 1, 2
  UNION ALL   -- the matrix total row: all airlines
  SELECT 'Total', d.fiscal_quarter, DATE_TRUNC(quarter, MIN(d.calendar_date)),
         SUM(u.total_cost_usd) / NULLIF(SUM(u.meals_uplifted), 0)
  FROM {S}FACT_CATERING_UPLIFT u {dims('u')} GROUP BY 2)
SELECT t.airline_name, t.fiscal_quarter, t.qs, t.cpm AS cost_per_meal, t.cpm / p.cpm - 1 AS delta_vs_pq
FROM t LEFT JOIN t p ON p.airline_name = t.airline_name AND p.qs = DATEADD(quarter, -1, t.qs)"""
# Cost per Meal and Cost per Meal Δ vs PQ % (previous quarter) by airline and quarter.

COST_BY_AIRLINE_TOTAL = f"""
SELECT a.airline_name, SUM(u.total_cost_usd) / NULLIF(SUM(u.meals_uplifted), 0) AS cost_per_meal
FROM {S}FACT_CATERING_UPLIFT u {dims('u', airline=True)} GROUP BY 1
UNION ALL
SELECT 'Total', SUM(total_cost_usd) / NULLIF(SUM(meals_uplifted), 0) FROM {S}FACT_CATERING_UPLIFT"""


def cost_split(grain, quarter=None):
    """Food, Labour and Overhead Cost per Meal."""
    return f"""
SELECT {period(grain)} AS period_label, MIN(d.calendar_date) AS period_sort,
       SUM(u.food_cost_usd) / NULLIF(SUM(u.meals_uplifted), 0) AS food,
       SUM(u.labour_cost_usd) / NULLIF(SUM(u.meals_uplifted), 0) AS labour,
       SUM(u.overhead_cost_usd) / NULLIF(SUM(u.meals_uplifted), 0) AS overhead
FROM {S}FACT_CATERING_UPLIFT u {dims('u')} WHERE {where(quarter=quarter)} GROUP BY 1"""


def late_downlift(grain, quarter=None):
    """Late Downlift Rate %: late downlift confirmations / flights catered."""
    return f"""
SELECT {period(grain)} AS period_label, MIN(d.calendar_date) AS period_sort,
       SUM(u.late_downlift_confirmations) / NULLIF(SUM(u.flights_catered), 0) AS late_rate
FROM {S}FACT_CATERING_UPLIFT u {dims('u')} WHERE {where(quarter=quarter)} GROUP BY 1"""


# ---------------------------------------------------------------- 3. Wastage by route group
AIRLINES = f"SELECT DISTINCT airline_name FROM {S}DIM_AIRLINE ORDER BY 1"


def wastage_trend(grain, airlines, quarter=None):
    """Wastage % by route group."""
    return f"""
SELECT {period(grain)} AS period_label, MIN(d.calendar_date) AS period_sort, u.route_group,
       SUM(u.meals_wasted) / NULLIF(SUM(u.meals_uplifted), 0) AS wastage
FROM {S}FACT_CATERING_UPLIFT u {dims('u', airline=True)} WHERE {where(quarter=quarter, airlines=airlines)} GROUP BY 1, 3"""


def wastage_month(airlines, month="2026-09"):
    """Meals Uplifted, Wastage % and Wastage Alert by airline and route group for one month, with a total row."""
    w = f"d.fiscal_period = {q(month)} AND {where(airlines=airlines)}"
    return f"""
SELECT * FROM (
  SELECT a.airline_name, u.route_group, SUM(u.meals_uplifted) AS meals_uplifted,
         SUM(u.meals_wasted) / NULLIF(SUM(u.meals_uplifted), 0) AS wastage, 0 AS is_total
  FROM {S}FACT_CATERING_UPLIFT u {dims('u', airline=True)} WHERE {w} GROUP BY 1, 2
  UNION ALL
  SELECT 'Total', NULL, SUM(u.meals_uplifted), SUM(u.meals_wasted) / NULLIF(SUM(u.meals_uplifted), 0), 1
  FROM {S}FACT_CATERING_UPLIFT u {dims('u', airline=True)} WHERE {w})
ORDER BY is_total, wastage DESC"""
