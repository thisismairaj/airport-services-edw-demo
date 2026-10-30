"""Pages 1-3: Group scorecard, Catering cost per meal, Wastage by route group (titles as in Power BI).
Drill-down: click a quarter to split it into its months, as the Power BI drill arrows do."""
import altair as alt
import pandas as pd
import streamlit as st

import queries_ops as Q
from kpis import LABOUR_FROM, LABOUR_NOTE, UP_BAD, UP_GOOD, Window, kpi
from ui import local_time, USD, MEAL, FLIGHT, PCT, bars, period_columns, period_lines, picked, run, table


def drilled(chart_event, name):
    """Quarter clicked in a chart (or None); the caption tells the viewer how to go back."""
    quarter = picked(chart_event, name, "period_label")
    if quarter:
        st.caption(f"Showing the months of **{quarter}**. Click the quarter again to go back.")
    return quarter


def scorecard(years_all, entities_all):
    f1, f2 = st.columns([1, 2])
    years = f1.multiselect("Fiscal year", years_all, placeholder="All years", key="sc_years")
    entities = f2.multiselect("Entity", entities_all, placeholder="All companies", key="sc_entities")
    w = Window(run(Q.scorecard_monthly(entities)), years)
    row1, row2 = st.columns(4), st.columns(4)
    cards = [   # label, value parts, format, change, colour (good when up?)
        ("Revenue (USD)", ("revenue",), USD, w.yoy("revenue"), UP_GOOD),   # growth on last year, the exec's first question
        ("EBITDA (USD)", ("ebitda",), USD, w.vs_budget("ebitda", "ebitda_budget"), UP_GOOD),
        ("EBITDA Margin %", ("ebitda", "revenue"), PCT, w.yoy("ebitda", "revenue", points=True), UP_GOOD),
        ("Cost per Meal (USD)", ("catering_cost", "meals"), MEAL, w.yoy("catering_cost", "meals"), UP_BAD),
        ("Cost per Flight Serviced (USD)", ("gh_cost", "flights"), FLIGHT, w.yoy("gh_cost", "flights"), UP_BAD),
        ("SLA Compliance %", ("sla_met", "sla_events"), PCT, w.yoy("sla_met", "sla_events", points=True), UP_GOOD),
        ("Wastage %", ("wasted", "meals"), PCT, w.yoy("wasted", "meals", points=True), UP_BAD),
        ("Overtime Ratio %", ("ot_hours", "all_hours"), PCT, None, UP_BAD)]   # labour: see kpis.LABOUR_NOTE
    for col, (label, parts, fmt, delta, colour) in zip(row1 + row2, cards):
        labour = parts[0] == "ot_hours"
        kpi(col, label, w.total(*parts), fmt, delta, colour, w.trend(*parts, start=LABOUR_FROM if labour else None),
            help=LABOUR_NOTE if labour else "Change vs budget, same months." if "budget" in (delta or "") else w.basis)

    c1, c2 = st.columns([2, 1])
    rev = run(Q.revenue_ebitda("Quarter", years, entities))
    ev = c1.altair_chart(period_lines(rev, {"revenue": "Revenue", "ebitda": "EBITDA"},
                                      "Revenue and EBITDA (USD), quarter > month: click a quarter", USD, select="rq"),
                         use_container_width=True, on_select="rerun", key="sc_rev")
    cpm = run(Q.cost_per_meal_trend("Quarter", years, entities))
    ec = c2.altair_chart(period_columns(cpm, {"cost_per_meal": "Cost per meal"},
                                        "Cost per meal (USD), quarter > month: click a quarter", MEAL, select="cq"),
                         use_container_width=True, on_select="rerun", key="sc_cpm")
    with c1:
        quarter = drilled(ev, "rq")
        if quarter:
            st.altair_chart(period_lines(run(Q.revenue_ebitda("Month", years, entities, quarter)),
                                         {"revenue": "Revenue", "ebitda": "EBITDA"}, f"{quarter} by month (USD)", USD, height=240),
                            use_container_width=True)
    with c2:
        quarter = drilled(ec, "cq")
        if quarter:
            st.altair_chart(period_columns(run(Q.cost_per_meal_trend("Month", years, entities, quarter)),
                                           {"cost_per_meal": "Cost per meal"}, f"{quarter} by month (USD)", MEAL, height=240),
                            use_container_width=True)

    c = run(Q.CERTIFICATION).iloc[0]
    st.info(f"**Data certification:** Certified {local_time(c.certified_at)} | Recon {c.recon_passed:.0%} passed")


def cost_per_meal():
    m = run(Q.COST_BY_AIRLINE_QUARTER)
    quarters = m.sort_values("qs").fiscal_quarter.unique().tolist()
    wide = m.pivot(index="airline_name", columns="fiscal_quarter", values=["cost_per_meal", "delta_vs_pq"])
    cols, fmts = {}, {}
    for qtr in quarters:   # each quarter: cost per meal, then the change vs the previous quarter
        cols[f"{qtr} cost"], cols[f"{qtr} Δ vs PQ"] = wide[("cost_per_meal", qtr)], wide[("delta_vs_pq", qtr)]
        fmts[f"{qtr} cost"], fmts[f"{qtr} Δ vs PQ"] = MEAL, "+.1%"
    grid = pd.DataFrame(cols)
    grid["Total cost"] = run(Q.COST_BY_AIRLINE_TOTAL).set_index("airline_name").cost_per_meal
    fmts["Total cost"] = MEAL
    grid = grid.reset_index().rename(columns={"airline_name": "Airline"})
    grid = pd.concat([grid[grid.Airline != "Total"].sort_values("Airline"), grid[grid.Airline == "Total"]])
    st.subheader("Cost per meal by airline and quarter")
    table(grid, fmts)

    c1, c2 = st.columns([1, 1])
    q3 = m[(m.fiscal_quarter == "FY26 Q3") & (m.airline_name != "Total")]
    c1.altair_chart(bars(q3, "airline_name", {"delta_vs_pq": "Δ vs previous quarter"}, "FY26 Q3: change vs previous quarter", "+.1%"),
                    use_container_width=True)
    split = {"food": "Food", "labour": "Labour", "overhead": "Overhead"}
    es = c2.altair_chart(period_columns(run(Q.cost_split("Quarter")), split,
                                        "What drives cost per meal: food, labour, overhead (click a quarter)", MEAL, select="sq"),
                         use_container_width=True, on_select="rerun", key="cpm_split")
    with c2:
        quarter = drilled(es, "sq")
        if quarter:
            st.altair_chart(period_columns(run(Q.cost_split("Month", quarter)), split, f"{quarter} by month (USD)", MEAL, height=240),
                            use_container_width=True)
    el = st.altair_chart(period_lines(run(Q.late_downlift("Quarter")), {"late_rate": "Late downlift rate"},
                                      "Late downlift confirmations per flight, quarter > month: click a quarter", PCT, select="lq"),
                         use_container_width=True, on_select="rerun", key="cpm_late")
    quarter = drilled(el, "lq")
    if quarter:
        st.altair_chart(period_lines(run(Q.late_downlift("Month", quarter)), {"late_rate": "Late downlift rate"},
                                     f"{quarter} by month", PCT, height=240), use_container_width=True)


def wastage():
    left, right = st.columns([1, 3])
    airlines = left.multiselect("Airline", run(Q.AIRLINES).airline_name.tolist(), placeholder="All airlines", key="w_air")
    with right:
        trend = run(Q.wastage_trend("Quarter", airlines))
        ev = st.altair_chart(period_lines(trend, {"wastage": "Wastage %"}, "Wastage % by route group (alert above 4%), "
                                          "quarter > month: click a quarter", PCT, series="route_group", select="wq"),
                             use_container_width=True, on_select="rerun", key="w_trend")
        quarter = drilled(ev, "wq")
        if quarter:
            st.altair_chart(period_lines(run(Q.wastage_trend("Month", airlines, quarter)), {"wastage": "Wastage %"},
                                         f"{quarter} by month", PCT, series="route_group", height=260), use_container_width=True)
        sep = run(Q.wastage_month(airlines))
        sep["wastage_alert"] = sep.wastage.map(lambda v: "" if pd.isna(v) else "Above 4%" if v > 0.04 else "Within tolerance")
        st.subheader("September 2026 by airline and route group")
        table(sep.drop(columns="is_total").rename(columns={
            "airline_name": "Airline", "route_group": "Route group", "meals_uplifted": "Meals Uplifted",
            "wastage": "Wastage %", "wastage_alert": "Wastage Alert"}), {"Meals Uplifted": USD, "Wastage %": PCT})
