"""Chart and table helpers shared by every page of the Group Performance app.

Number rules (same as the Power BI measure formats): USD with no decimals,
cost per meal 3 decimals, cost per flight 2, hours 1, percentages 1. Cards and value labels show
full numbers (915,374); axes are shortened the way Power BI does it (500K, 2M).
Clickable charts are a single layer: Streamlit cannot read clicks on layered charts.
"""
import altair as alt
import pandas as pd
import streamlit as st
from snowflake.snowpark.context import get_active_session

USD, MEAL, FLIGHT, HOURS, PCT, DELTA_HRS = ",.0f", ",.3f", ",.2f", ",.1f", ".1%", "+,.0f"


@st.cache_data(ttl=600, show_spinner=False)
def run(sql):
    df = get_active_session().sql(sql).to_pandas()
    df.columns = [c.lower() for c in df.columns]
    return df


def picked(event, name, field):
    """The value the user clicked in a chart (selection param 'name'), or None."""
    sel = (event or {}).get("selection", {}).get(name) if isinstance(event, dict) else getattr(getattr(event, "selection", None), name, None)
    if isinstance(sel, list) and sel:
        return sel[0].get(field)
    if isinstance(sel, dict):
        v = sel.get(field)
        return v[0] if isinstance(v, list) and v else v
    return None


def compact_axis():
    """Axis ticks as 500K / 2M, the way Power BI shortens them."""
    return alt.Axis(format="~s", labelExpr="replace(datum.label, 'k', 'K')")


def value_axis(fmt):
    return compact_axis() if fmt == USD else alt.Axis(format=fmt)


def period_x(df):
    """Periods in time order (period_sort), labelled with period_label."""
    return alt.X("period_label:N", sort=df.sort_values("period_sort")["period_label"].unique().tolist(), title=None)


def melt(df, keys, cols):
    long = df.melt(id_vars=keys, value_vars=list(cols), var_name="series", value_name="value")
    long["series"] = long["series"].map(cols)
    return long


def legend(names):
    return alt.Color("series:N", title=None, sort=list(names), legend=alt.Legend(orient="bottom"))


def bars(df, cat, cols, title, fmt, select=None, sort=True, height=None):
    """Horizontal bars with values printed on them; cols = {column: legend label}.
    select = a name makes the bars clickable (values on hover instead); read the click with picked()."""
    long = melt(df, [cat], cols)
    order = df.sort_values(list(cols)[0], ascending=False)[cat].tolist() if sort else df[cat].tolist()
    base = alt.Chart(long, title=title).encode(
        y=alt.Y(f"{cat}:N", sort=order, title=None), yOffset=alt.YOffset("series:N", sort=list(cols.values())),
        x=alt.X("value:Q", title=None, axis=value_axis(fmt)))
    colour = legend(cols.values()) if len(cols) > 1 else alt.value("#2f6fd8")
    bar = base.mark_bar().encode(color=colour, tooltip=[alt.Tooltip(f"{cat}:N", title=""), alt.Tooltip("series:N", title=""),
                                                       alt.Tooltip("value:Q", format=fmt, title="")])
    height = height or max(220, 26 * len(order) * len(cols))
    if select:
        return bar.add_params(alt.selection_point(fields=[cat], name=select)).properties(height=height)
    label = alt.Text("value:Q", format=fmt)
    text = (base.transform_filter("datum.value >= 0").mark_text(align="left", dx=3, fontSize=10).encode(text=label)
            + base.transform_filter("datum.value < 0").mark_text(align="right", dx=-3, fontSize=10).encode(text=label))
    return (bar + text).properties(height=height)


def period_columns(df, cols, title, fmt, select=None, height=300):
    """Columns per period (time order), one colour per measure; no value labels on period axes (as Power BI).
    select = a name makes a period clickable (drill down to the next finer period)."""
    long = melt(df, ["period_label", "period_sort"], cols)
    colour = legend(cols.values()) if len(cols) > 1 else alt.value("#2f6fd8")
    chart = alt.Chart(long, title=title).mark_bar().encode(
        x=period_x(df), xOffset=alt.XOffset("series:N", sort=list(cols.values())),
        y=alt.Y("value:Q", title=None, axis=value_axis(fmt)), color=colour,
        tooltip=["period_label", alt.Tooltip("series:N", title=""), alt.Tooltip("value:Q", format=fmt, title="")])
    if select:
        chart = chart.add_params(alt.selection_point(fields=["period_label"], name=select))
    return chart.properties(height=height)


def period_lines(df, cols, title, fmt, series=None, select=None, height=300):
    """Lines per period (time order). series = a column to split lines by (instead of several measures)."""
    if series:
        long = df.rename(columns={list(cols)[0]: "value", series: "series"})
        colour = alt.Color("series:N", title=None, legend=alt.Legend(orient="bottom"))
    else:
        long = melt(df, ["period_label", "period_sort"], cols)
        colour = legend(cols.values())
    chart = alt.Chart(long, title=title).mark_line(point=True).encode(
        x=period_x(df), y=alt.Y("value:Q", title=None, axis=value_axis(fmt)), color=colour,
        tooltip=["period_label", alt.Tooltip("series:N", title=""), alt.Tooltip("value:Q", format=fmt, title="")])
    if select:
        chart = chart.add_params(alt.selection_point(fields=["period_label"], name=select))
    return chart.properties(height=height)


def table(df, formats, height=None):
    """A table with Power BI's number formats; formats = {column: d3-style format}."""
    py = {c: "{:" + f + "}" for c, f in formats.items()}
    size = {"height": height} if height else {}   # Streamlit 1.50 rejects height=None
    st.dataframe(df.style.format(py, na_rep=""), use_container_width=True, hide_index=True, **size)


def local_time(ts):
    """Snowflake timestamps arrive in UTC; show them in Bayport time, labelled."""
    t = pd.Timestamp(ts)
    t = (t.tz_localize("UTC") if t.tzinfo is None else t).tz_convert("Etc/GMT-3")
    return f"{t:%d %b %Y %H:%M} Bayport time"
