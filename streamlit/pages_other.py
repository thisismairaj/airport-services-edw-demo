"""Pages 4-7: Airline P&L, GSE reliability, People and contractors, Governance (titles as in Power BI).
Drill-down: click an account manager to see their airlines, a quarter to see its months, a company to
see its shift patterns, as the Power BI drill arrows do."""
import pandas as pd
import streamlit as st

import queries_other as X
from pages_ops import drilled
from kpis import LABOUR_FROM, LABOUR_NOTE, NEUTRAL, UP_BAD, UP_GOOD, Window, kpi
from ui import local_time, USD, DELTA_HRS, HOURS, PCT, bars, period_columns, period_lines, picked, run, table


def airline_pnl():
    f1, f2, c1, c2 = st.columns([2, 1, 1, 1])
    managers = f1.multiselect("Account manager", run(X.MANAGERS).account_manager.tolist(), placeholder="All", key="p_mgr")
    years = f2.multiselect("Fiscal year", run(X.PNL_YEARS).fiscal_year.tolist(), placeholder="All years", key="p_years")
    w = Window(run(X.pnl_monthly(managers)), years)
    kpi(c1, "Revenue (USD)", w.total("revenue"), USD, w.yoy("revenue"), UP_GOOD, w.trend("revenue"), help=w.basis)
    kpi(c2, "Margin %", w.total("margin_usd", "revenue"), PCT, w.yoy("margin_usd", "revenue", points=True), UP_GOOD,
        w.trend("margin_usd", "revenue"), help=w.basis)

    left, right = st.columns([1, 1])
    by_mgr = run(X.pnl_by("manager", managers, years))
    er = left.altair_chart(bars(by_mgr, "item", {"revenue": "Revenue"}, "Revenue (USD), account manager > airline: click a manager",
                                USD, select="pr"), use_container_width=True, on_select="rerun", key="p_rev")
    em = right.altair_chart(bars(by_mgr, "item", {"margin": "Margin %"}, "Margin %, account manager > airline: click a manager",
                                 PCT, select="pm"), use_container_width=True, on_select="rerun", key="p_margin")
    for col, ev, name, field, fmt in ((left, er, "pr", "revenue", USD), (right, em, "pm", "margin", PCT)):
        manager = picked(ev, name, "item")
        if manager:
            with col:
                st.caption(f"Airlines of **{manager}**. Click the manager again to go back.")
                st.altair_chart(bars(run(X.pnl_by("airline", managers, years, manager)), "item",
                                     {field: "Revenue" if field == "revenue" else "Margin %"}, f"{manager}'s airlines", fmt),
                                use_container_width=True)
    et = st.altair_chart(period_lines(run(X.pnl_trend("Quarter", managers, years)), {"revenue": "Revenue"},
                                      "Airline revenue (USD), quarter > month: click a quarter", USD, select="pq"),
                         use_container_width=True, on_select="rerun", key="p_trend")
    quarter = drilled(et, "pq")
    if quarter:
        st.altair_chart(period_lines(run(X.pnl_trend("Month", managers, years, quarter)), {"revenue": "Revenue"},
                                     f"{quarter} by month (USD)", USD, height=240), use_container_width=True)


def gse():
    assets = run(X.ASSETS).asset_id.tolist()
    asset = st.selectbox("Asset (Power BI page filter)", assets, index=assets.index("T-114") if "T-114" in assets else 0, key="g_asset")
    m = run(X.asset_months(asset))
    c1, c2 = st.columns([1.6, 1])
    cost = m[m.cost.notna() | m.baseline.notna()]
    c1.altair_chart(period_lines(cost, {"cost": "Asset Downtime Cost", "baseline": "Downtime Cost 6M Baseline"},
                                 "Downtime cost vs six-month baseline (USD)", USD, height=320), use_container_width=True)
    faults = m[m.hyd.notna() | m.hyd_3m.notna()]
    c2.altair_chart(period_columns(faults, {"hyd": "Hydraulic Faults", "hyd_3m": "Hydraulic Faults 3M"},
                                   "Hydraulic faults: month and rolling three months", ",.0f", height=320), use_container_width=True)
    t1, t2 = st.columns([1, 1])
    with t1:
        st.subheader("Asset status history (SCD2 versions)")
        v = run(X.asset_versions(asset))
        for c in ("effective_from", "effective_to"):
            v[c] = pd.to_datetime(v[c], errors="coerce").dt.strftime("%d %b %Y").fillna("31 Dec 9999")
        table(v.rename(columns={"asset_id": "Asset", "version_no": "Version", "status": "Status",
                                 "effective_from": "Effective from", "effective_to": "Effective to"}), {})
    with t2:
        st.subheader("Reliability by month")
        table(run(X.asset_reliability(asset)).rename(columns={
            "fiscal_period": "Month", "operating_hours": "Operating Hours", "mtbf": "MTBF Hours", "mttr": "MTTR Hours"}),
            {"Operating Hours": HOURS, "MTBF Hours": HOURS, "MTTR Hours": HOURS})


def people():
    c1, c2 = st.columns([1, 1])
    ot = run(X.CONTRACTOR_OT)
    c1.altair_chart(period_columns(ot, {"contractor_ot": "Contractor OT Hours"}, "Contractor overtime hours", HOURS, height=300),
                    use_container_width=True)
    c2.altair_chart(period_columns(ot[ot.delta_vs_pm.notna()], {"delta_vs_pm": "Contractor OT Δ vs PM (hrs)"},
                                  "Contractor overtime: change vs previous month (hours)", DELTA_HRS, height=300),
                    use_container_width=True)
    left, right = st.columns([1, 1])
    by_entity = run(X.overtime_ratio_by())
    ee = left.altair_chart(bars(by_entity, "item", {"ot_ratio": "Overtime Ratio %"}, "Overtime ratio, company > shift pattern: "
                                "click a company", PCT, select="oe"), use_container_width=True, on_select="rerun", key="pe_ot")
    entity = picked(ee, "oe", "item")
    if entity:
        with left:
            st.caption(f"Shift patterns at **{entity}**. Click the company again to go back.")
            shifts = run(X.overtime_ratio_by(entity)).fillna({"item": "(Blank)"})
            st.altair_chart(bars(shifts, "item", {"ot_ratio": "Overtime Ratio %"}, f"{entity} by shift pattern", PCT),
                            use_container_width=True)
    w = Window(run(X.PEOPLE_MONTHLY))
    spend, budget = w.total("contractor_spend"), w.total("contractor_budget")
    over = (spend - budget) / budget if budget else None
    r1, r2 = right.columns(2), right.columns(2)
    kpi(r1[0], "Contractor Spend vs Budget %", over, "+.1%",
        None if over is None else f"{over:+.1%} {'over' if over > 0 else 'under'} budget", UP_BAD,
        w.trend("contractor_spend", "contractor_budget"), help="Trend: contractor spend as a share of budget, month by month.")
    kpi(r1[1], "Labour cost (USD)", w.total("labour_cost"), USD, None, NEUTRAL, w.trend("labour_cost", start=LABOUR_FROM),
        help=LABOUR_NOTE)
    kpi(r2[0], "Overtime Ratio %", w.total("ot_hours", "all_hours"), PCT, None, UP_BAD,
        w.trend("ot_hours", "all_hours", start=LABOUR_FROM), help=LABOUR_NOTE)
    kpi(r2[1], "Active Employees", run(X.ACTIVE_EMPLOYEES).active.iloc[0], ",.0f",
        help="Today's headcount from the employee master; it keeps no history, so there is no change or trend.")


def governance():
    k = run(X.GOVERNANCE_CARDS).iloc[0]
    c = st.columns(4)
    kpi(c[0], "Recon Checks Passed %", k.recon_passed, PCT)
    c[1].metric("Data Certified As Of", local_time(k.certified_at), border=True)
    kpi(c[2], "Golden Vendors", k.golden_vendors, ",.0f")
    kpi(c[3], "Source Vendor Ids", k.source_vendor_ids, ",.0f")
    t1, t2 = st.columns([1, 1])
    with t1:
        st.subheader("Reconciliation, latest run")
        table(run(X.RECON), {"variance": ",.2f"}, height=520)
    with t2:
        st.subheader("Certified measure catalogue")
        table(run(X.CATALOG), {}, height=520)
