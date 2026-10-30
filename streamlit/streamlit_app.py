"""Group executive cockpit - Finance, Operations, People & Governance, running inside Snowflake (Streamlit in Snowflake).

The same seven pages, titles and numbers as the Power BI report (powerbi/ASC_Group_Performance.pbip),
plus ASC AI (a Cortex Analyst chat over the certified semantic view), all
read from EDW_GOLD. The app runs as its owner, ROLE_GROUP_EXEC, so everyone who opens it sees the group
executive's view (all companies and airlines; HR personal data masked by the Snowflake policies).
Persona security (airline managers, HR, finance) is shown in Power BI and SQL, which connect as each persona.
All SQL lives in queries_ops.py / queries_other.py; Snowflake does the work and only small results come back.
"""
import streamlit as st

st.set_page_config(page_title="Group executive cockpit - Finance, Operations, People & Governance", layout="wide")

import pages_ops as P1      # noqa: E402  (set_page_config must run first)
import pages_other as P2    # noqa: E402
import pages_ai             # noqa: E402
import queries_ops as Q     # noqa: E402
from ui import run          # noqa: E402

st.title("Group executive cockpit - Finance, Operations, People & Governance")
st.caption("Group executive view · USD · certified Gold data in Snowflake (UAE)")

years = run(f"SELECT DISTINCT fiscal_year FROM {Q.S}DIM_DATE ORDER BY 1").fiscal_year.tolist()
entities = run(f"SELECT entity_code FROM {Q.S}DIM_ENTITY ORDER BY 1").entity_code.tolist()

# Tabs by department; the Power BI pages carry the same names
tabs = st.tabs(["Executive", "Catering: Unit Cost", "Catering: Wastage", "Airline Services",
                "Maintenance", "Human Resources", "Data Governance", "Ask ASC AI"])
with tabs[0]:
    P1.scorecard(years, entities)
with tabs[1]:
    P1.cost_per_meal()
with tabs[2]:
    P1.wastage()
with tabs[3]:
    P2.airline_pnl()
with tabs[4]:
    P2.gse()
with tabs[5]:
    P2.people()
with tabs[6]:
    P2.governance()
with tabs[7]:
    pages_ai.page()
