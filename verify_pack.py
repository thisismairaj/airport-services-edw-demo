#!/usr/bin/env python3
"""Checks that every CSV header matches the CREATE TABLE column list in the SQL (name + order),
that Gold facts' foreign keys resolve, that story numbers are present, and that the YAML parses."""
import os, re, csv, json, sys
import pandas as pd

BASE = os.path.dirname(os.path.abspath(__file__))
ok = True

def ddl_columns(sql_text):
    """table_name -> [columns] for every CREATE [OR REPLACE] TABLE with an inline column list."""
    out = {}
    for m in re.finditer(r'CREATE (?:OR REPLACE )?TABLE (?:IF NOT EXISTS )?([A-Z0-9_.]+)\s*\((.*?)\)\s*(?:COMMENT\s*=\s*\'[^\']*\'\s*)?;', sql_text, re.S | re.I):
        name = m.group(1).split('.')[-1].upper()
        body = m.group(2)
        cols = []
        depth = 0; tok = ''
        for ch in body:
            if ch == '(':
                depth += 1
            elif ch == ')':
                depth -= 1
            if ch == ',' and depth == 0:
                cols.append(tok.strip()); tok = ''
            else:
                tok += ch
        if tok.strip():
            cols.append(tok.strip())
        cols = [re.sub(r'--.*', '', c).strip() for c in cols]
        cols = [c.split()[0].upper() for c in cols if c and not c.upper().startswith(('PRIMARY KEY', 'CONSTRAINT'))]
        out[name] = cols
    return out

def check(csv_path, cols, label):
    global ok
    with open(csv_path, newline='') as fh:
        header = [h.upper() for h in next(csv.reader(fh))]
    if header == cols:
        print(f'  OK   {label:40s} {len(cols)} cols')
    else:
        ok = False
        print(f'  FAIL {label}')
        print('       csv :', header); print('       ddl :', cols)

print('Bronze CSV vs 02_bronze_load.sql')
b = ddl_columns(open(os.path.join(BASE, 'sql', '02_bronze_load.sql')).read())
for f in sorted(os.listdir(os.path.join(BASE, 'data', 'bronze'))):
    t = f[:-4].upper()
    if t not in b:
        ok = False; print(f'  FAIL no DDL for {t}'); continue
    check(os.path.join(BASE, 'data', 'bronze', f), b[t], t)
# daily drop files: same business columns as CONTRACTOR_FEED_DAILY minus audit
clean_hdr = [h.upper() for h in next(csv.reader(open(os.path.join(BASE, 'data', 'bad_files', 'contractor_feed_2026-09-28_clean.csv'))))]
daily_ddl = b['CONTRACTOR_FEED_DAILY'][:14]
print('  OK   clean daily file matches CONTRACTOR_FEED_DAILY business columns' if clean_hdr == daily_ddl else '  FAIL clean daily file'); ok &= clean_hdr == daily_ddl
bad_hdr = [h.upper() for h in next(csv.reader(open(os.path.join(BASE, 'data', 'bad_files', 'contractor_feed_2026-09-28_malformed.csv'))))]
print(f'  OK   malformed file has {len(bad_hdr)} of 14 columns (missing {sorted(set(daily_ddl) - set(bad_hdr))})')

print('Gold CSV vs 04_gold_model.sql')
g = ddl_columns(open(os.path.join(BASE, 'sql', '04_gold_model.sql')).read())
for f in sorted(os.listdir(os.path.join(BASE, 'data', 'gold'))):
    t = f[:-4].upper()
    if t not in g:
        ok = False; print(f'  FAIL no DDL for {t}'); continue
    check(os.path.join(BASE, 'data', 'gold', f), g[t], t)

print('Referential integrity of Gold facts')
G = lambda n: pd.read_csv(os.path.join(BASE, 'data', 'gold', n + '.csv'))
dims = {k: set(G(t)[c]) for k, (t, c) in {'date_key': ('DIM_DATE', 'date_key'), 'entity_key': ('DIM_ENTITY', 'entity_key'), 'station_key': ('DIM_STATION', 'station_key'),
        'airline_key': ('DIM_AIRLINE', 'airline_key'), 'meal_key': ('DIM_MEAL', 'meal_key'), 'cost_center_key': ('DIM_COST_CENTER', 'cost_center_key'),
        'gl_account_key': ('DIM_GL_ACCOUNT', 'gl_account_key'), 'asset_key': ('DIM_ASSET', 'asset_key'), 'vendor_key': ('DIM_VENDOR', 'vendor_key')}.items()}
dims['deployed_cost_center_key'] = dims['cost_center_key']
for fact in ['FACT_CATERING_UPLIFT', 'FACT_FINANCE_POSTING', 'FACT_WORK_ORDER', 'FACT_LABOUR_COST', 'FACT_AIRLINE_ORDER', 'FACT_PURCHASE_ORDER', 'AGG_DAILY_FLIGHTS', 'AGG_MONTHLY_ASSET_RELIABILITY']:
    df = G(fact)
    for c in df.columns:
        if c in dims:
            orphans = set(df[c].dropna().astype(int)) - dims[c]
            if orphans:
                ok = False; print(f'  FAIL {fact}.{c}: {len(orphans)} orphan keys e.g. {list(orphans)[:3]}')
    print(f'  OK   {fact:32s} {len(df):>6} rows, FKs resolve')

print('Story checks')
fcu = G('FACT_CATERING_UPLIFT').merge(G('DIM_DATE')[['date_key', 'fiscal_quarter']], on='date_key').merge(G('DIM_AIRLINE')[['airline_key', 'airline_code']], on='airline_key')
q = fcu[fcu.fiscal_quarter.isin(['FY26 Q2', 'FY26 Q3'])].groupby(['airline_code', 'fiscal_quarter']).agg(c=('total_cost_usd', 'sum'), m=('meals_uplifted', 'sum'))
cpm = (q.c / q.m).unstack(); chg = (cpm['FY26 Q3'] / cpm['FY26 Q2'] - 1) * 100
print('  cost/meal Q3 vs Q2 FY26 %:', chg.round(1).to_dict())
ok &= all(chg[a] > 8 for a in ['EK', 'FZ', 'CHR']) and all(abs(chg[a]) < 3 for a in ['GC', 'QR', 'BA'])
gfe = fcu[(fcu.airline_code == 'GC') & (fcu.route_group == 'Europe') & (fcu.date_key // 100 == 202609)]
w = 100 * gfe.meals_wasted.sum() / gfe.meals_uplifted.sum(); print(f'  GC Europe wastage Sep-2026: {w:.2f}%'); ok &= w > 4
lab = G('FACT_LABOUR_COST'); c = lab[(lab.employment_type == 'Contractor')].groupby('fiscal_period').overtime_hours.sum()
print(f'  ASCWF contractor OT Aug->Sep 2026: {int(c["2026-08"])} -> {int(c["2026-09"])} (delta {int(c["2026-09"] - c["2026-08"])})'); ok &= int(c['2026-09'] - c['2026-08']) == 318
rel = G('AGG_MONTHLY_ASSET_RELIABILITY'); t = rel[rel.asset_id == 'T-114'].set_index('fiscal_period')
print('  T-114 downtime cost last 4 months:', t.downtime_cost_usd.tail(4).round(0).to_dict(), '| hydraulic faults:', t.hydraulic_faults.tail(4).to_dict())
ok &= t.downtime_cost_usd['2026-09'] > 3 * t.downtime_cost_usd['2026-03':'2026-08'].mean()
vm = pd.read_csv(os.path.join(BASE, 'data', 'bronze', 'sap_vendor_master.csv')); dv = G('DIM_VENDOR')
print(f'  vendor master {len(vm)} raw -> {len(dv)} golden ({(dv.duplicate_source_ids.fillna("") != "").sum()} with duplicates)'); ok &= len(vm) - len(dv) == 17
live = pd.read_csv(os.path.join(BASE, 'data', 'bronze', 'cms_uplift_flight_class.csv'))
print(f'  CMS live feed: {len(live)} rows, {len(live) - live.UPLIFT_ID.nunique()} exact duplicates, {(live.CARRIER != live.CARRIER.str.upper()).sum()} lower-case carriers')
gl = G('FACT_FINANCE_POSTING').merge(G('DIM_GL_ACCOUNT'), on='gl_account_key'); ext = gl[~gl.is_intercompany]
for fy in (2025, 2026):
    s = ext[ext.fiscal_year == fy]; rev = -s[s.account_class == 'Revenue'].amount_usd.sum(); eb = -s[s.is_ebitda].amount_usd.sum()
    print(f'  FY{fy}: revenue USD {rev:,.0f}, EBITDA {eb:,.0f} ({100*eb/rev:.1f}%)')

print('YAML semantic model')
try:
    import yaml
    y = yaml.safe_load(open(os.path.join(BASE, 'sql', '08_cortex_analyst_semantic_model.yaml')))
    print(f'  OK   {len(y["tables"])} tables, {len(y["verified_queries"])} verified queries, {sum(len(t.get("measures", [])) + len(t.get("metrics", [])) for t in y["tables"])} measures+metrics')
except ImportError:
    print('  SKIP pyyaml not installed')

print('SQL sanity (balanced parentheses, statements end with ;)')
for f in sorted(os.listdir(os.path.join(BASE, 'sql'))):
    if f.endswith('.sql'):
        s = open(os.path.join(BASE, 'sql', f)).read()
        s_nc = re.sub(r'--.*', '', s); s_nc = re.sub(r"'(?:[^']|'')*'", "''", s_nc)
        bal = s_nc.count('(') - s_nc.count(')')
        print(f'  {"OK  " if bal == 0 else "FAIL"} {f:40s} parens {bal:+d}, {s.count(";")} statements')
        ok &= bal == 0

total = sum(os.path.getsize(os.path.join(r, f)) for r, _, fs in os.walk(os.path.join(BASE, 'data')) for f in fs)
print(f'\nData size: {total/1048576:.2f} MB  -> {"OK" if total < 15 * 1048576 else "OVER 15 MB"}')
print('RESULT:', 'ALL CHECKS PASSED' if ok else 'FAILURES')
sys.exit(0 if ok else 1)
