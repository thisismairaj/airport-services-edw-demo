"""Page 8: ASC AI - ask in plain English, answered by Cortex Analyst over the certified semantic view
EDW_GOLD.SEMANTIC.GROUP_PERFORMANCE (the same engine as the Snowsight Cortex Analyst demo).

Each answer shows Analyst's reading of the question, the result table, a chart and the SQL it ran.
Layout like ChatGPT: conversation window above, input box under it, newest turn just above the input.
The SQL runs as the app's owner role, so the Snowflake masking and row policies apply as everywhere else.
Analyst returns SQL and an explanation, not a written summary: that would need the general LLM functions,
which this trial account blocks. Conversation rule: the history sent to Analyst must alternate user /
analyst, so a question that fails is dropped, never kept unanswered.
"""
import json

import _snowflake
import altair as alt
import pandas as pd
import streamlit as st

from ui import run

SEMANTIC_VIEW = "EDW_GOLD.SEMANTIC.GROUP_PERFORMANCE"
STARTERS = ["Which airline contracts had the highest cost per meal last quarter?",
            "Is tug T-114 getting worse? Show downtime cost by month.",
            "How much did contractor overtime at ASCWF change in September 2026?",
            "What was revenue and EBITDA by entity in FY26 Q3?"]


def ask_analyst(messages):
    """POST the conversation to Cortex Analyst; returns (analyst message, error text)."""
    body = {"messages": messages, "semantic_view": SEMANTIC_VIEW}
    resp = _snowflake.send_snow_api_request("POST", "/api/v2/cortex/analyst/message", {}, {}, body, None, 50000)
    content = json.loads(resp["content"]) if isinstance(resp.get("content"), str) else resp.get("content")
    if resp.get("status", 500) >= 400:
        return None, (content or {}).get("message", f"Cortex Analyst returned status {resp.get('status')}")
    return content["message"], None


def chart(df):
    """A line over time when there is a date or period column, else bars by the first text column."""
    if df is None or len(df) < 2 or len(df) > 60:
        return None
    nums = [c for c in df.columns if pd.api.types.is_numeric_dtype(df[c]) and not c.lower().endswith(("_key", "_id", "year"))]
    if not nums:
        return None
    time = [c for c in df.columns if pd.api.types.is_datetime64_any_dtype(df[c]) or any(
        w in c.lower() for w in ("date", "period", "month", "quarter", "week"))]
    text = [c for c in df.columns if df[c].dtype == object and c not in time]
    y = alt.Y(f"{nums[0]}:Q", title=nums[0].replace("_", " "))
    if time:
        c = alt.Chart(df).mark_line(point=True).encode(x=alt.X(f"{time[0]}:O", title=None, sort=None), y=y)
        return c.encode(color=f"{text[0]}:N") if text and df[text[0]].nunique() <= 10 else c
    if text:
        return alt.Chart(df).mark_bar().encode(y=alt.Y(f"{text[0]}:N", sort="-x", title=None), x=y)
    return None


def show_answer(turn):
    for item in turn["content"]:
        if item["type"] == "text":
            st.markdown(item["text"])
        elif item["type"] == "suggestions":
            st.caption("Did you mean:")
            for i, s in enumerate(item["suggestions"]):
                if st.button(s, key=f"sugg_{turn['n']}_{i}"):
                    st.session_state.ai_pending = s
                    st.rerun()
        elif item["type"] == "sql":
            df = turn.get("df")
            if turn.get("sql_error"):
                st.error(f"The query failed: {turn['sql_error']}")
            elif df is not None:
                st.dataframe(df, use_container_width=True, hide_index=True)
                c = chart(df)
                if c is not None:
                    st.altair_chart(c.properties(height=280), use_container_width=True)
            with st.expander("Show SQL (generated from the certified semantic model)"):
                st.code(item["statement"], language="sql")


def empty_state():
    """ChatGPT-style start screen inside the conversation window: a greeting and starter questions."""
    st.markdown("<div style='text-align:center; margin-top:90px'><h3>What would you like to know?</h3>"
                "<p style='color:grey'>Answers come from the certified semantic model, under the same Snowflake "
                "security as the rest of this app.</p></div>", unsafe_allow_html=True)
    left, right = st.columns(2)
    for i, q in enumerate(STARTERS):
        if (left if i % 2 == 0 else right).button(q, key=f"start_{i}", use_container_width=True):
            st.session_state.ai_pending = q


def page():
    """Layout like ChatGPT: the conversation in a window that keeps the newest message in view, the input box
    right under it, each new turn appearing at the bottom of the window, just above the input."""
    state = st.session_state
    state.setdefault("ai_messages", [])   # sent to Analyst: strict user / analyst alternation
    state.setdefault("ai_turns", [])      # shown on screen: question, Analyst's answer, the result table

    top = st.columns([6, 1])
    top[0].caption(f"Cortex Analyst over `{SEMANTIC_VIEW}`")
    if state.ai_turns and top[1].button("New conversation", use_container_width=True):
        state.ai_messages, state.ai_turns = [], []
        st.rerun()

    window = st.container(height=600, border=True)   # Streamlit keeps a chat window scrolled to the bottom
    with window:
        start = st.empty()
        if state.ai_turns:
            for turn in state.ai_turns:
                st.chat_message("user").write(turn["question"])
                with st.chat_message("assistant"):
                    show_answer(turn)
        else:
            with start.container():
                empty_state()

    question = st.chat_input("Ask ASC AI, e.g. 'Which route group had the highest wastage in September?'") or state.pop("ai_pending", None)
    if not question:
        return
    start.empty()   # the start screen gives way to the conversation
    with window:
        st.chat_message("user").write(question)
        with st.chat_message("assistant"), st.spinner("Cortex Analyst is reading the semantic model..."):
            user_msg = {"role": "user", "content": [{"type": "text", "text": question}]}
            answer, error = ask_analyst(state.ai_messages + [user_msg])
            if error:   # nothing stored: the next question starts from the last answered one
                st.error(error)
                return
            turn = {"n": len(state.ai_turns), "question": question, "content": answer["content"]}
            sql = next((c["statement"] for c in answer["content"] if c["type"] == "sql"), None)
            if sql:
                try:
                    turn["df"] = run(sql)
                except Exception as e:   # shown, not raised: the conversation carries on
                    turn["sql_error"] = str(e).splitlines()[0]
            state.ai_messages += [user_msg, {"role": "analyst", "content": answer["content"]}]
            state.ai_turns.append(turn)
            show_answer(turn)
