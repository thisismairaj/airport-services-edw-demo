"""KPI cards with a coloured change line and a 12-month trend (Streamlit's bordered metric).

Colour follows good or bad, not up or down: revenue up is green, cost per meal up is red.
Change is measured like for like: the months in view that have the same month a year earlier
(Jan-Sep 2026 vs Jan-Sep 2025), so an incomplete year never looks like a drop. Revenue, EBITDA and
contractor spend are compared with budget instead, because a budget exists for them.
Every KPI is a ratio of sums over the months, the same as the Power BI measures.
"""
import calendar

import pandas as pd

UP_GOOD, UP_BAD, NEUTRAL = "normal", "inverse", "off"   # Streamlit delta_color

# Labour data: 2025 holds contractors only, permanent staff start in Jan 2026 (see the README, size trade-offs).
# A year-on-year change would compare different groups of people, so labour cards show none, and their
# trend starts when the whole workforce is in the data.
LABOUR_FROM = "2026-01"
LABOUR_NOTE = ("No year-on-year change: 2025 labour data covers contractors only (permanent staff from Jan 2026), "
               "so it would compare different groups of people. Trend from Jan 2026.")


def year_ago(month):
    return f"{int(month[:4]) - 1}{month[4:]}"


def span(months):
    """'Jan-Sep 2025' for months in one year, else '2025-01 to 2025-09'."""
    if not months:
        return ""
    first, last = months[0], months[-1]
    if first[:4] == last[:4]:
        a, b = calendar.month_abbr[int(first[5:])], calendar.month_abbr[int(last[5:])]
        return f"{a}{'-' + b if a != b else ''} {first[:4]}"
    return f"{first} to {last}"


class Window:
    """The months in view (the year filter), and the like-for-like months used for the year-on-year change."""

    def __init__(self, monthly, years=()):
        self.df = monthly
        months = sorted(monthly.fiscal_period)
        self.current = [m for m in months if not years or int(m[:4]) in [int(y) for y in years]]
        self.compare = [m for m in self.current if year_ago(m) in months]
        self.prior = [year_ago(m) for m in self.compare]
        self.basis = f"Change: {span(self.compare)} vs {span(self.prior)}, the same months a year apart." if self.compare else ""

    def total(self, num, den=None, months=None):
        rows = self.df[self.df.fiscal_period.isin(self.current if months is None else months)]
        n = rows[num].sum()
        if den is None:
            return n
        d = rows[den].sum()
        return n / d if d else None

    def yoy(self, num, den=None, points=False):
        """'+3.0% vs Jan-Sep 2025' (or '+1.2 pts' for a percentage KPI); None when there is no year-ago month."""
        if not self.compare:
            return None
        now, before = self.total(num, den, self.compare), self.total(num, den, self.prior)
        if now is None or before is None or (not points and not before):
            return None
        change = f"{(now - before) * 100:+.1f} pts" if points else f"{now / before - 1:+.1%}"
        return f"{change} vs {span(self.prior)}"

    def vs_budget(self, actual, budget):
        a, b = self.total(actual), self.total(budget)
        return f"{(a - b) / abs(b):+.1%} vs budget" if b else None

    def trend(self, num, den=None, start=None):
        """The KPI month by month, last 12 months in view (the card's sparkline); start = first month to draw."""
        rows = self.df[self.df.fiscal_period.isin(self.current) & (self.df.fiscal_period >= (start or ""))].tail(12)
        values = rows[num] / rows[den].where(rows[den] != 0) if den else rows[num]
        return [float(v) for v in values if not pd.isna(v)]   # a month with no value is skipped: st.metric rejects None


def kpi(col, label, value, fmt, delta=None, colour=UP_GOOD, trend=None, help=None):
    """One bordered card: the value as a full number, the coloured change, the 12-month trend."""
    shown = "-" if value is None or pd.isna(value) else format(value, fmt)
    col.metric(label, shown, delta, delta_color=colour, border=True, chart_data=trend if trend and len(trend) > 1 else None, chart_type="line", help=help)
