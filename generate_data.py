#!/usr/bin/env python3
"""
ASC Snowflake + Power BI demo data pack generator.
Deterministic (seed 42). Produces Bronze-style raw extracts, Gold star-schema
CSVs, the quarantine (malformed) contractor file and its clean counterpart.

Run:  python3 -I generate_data.py
"""
import os, hashlib, json
import numpy as np
import pandas as pd

SEED = 42
rng = np.random.default_rng(SEED)
BASE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(BASE, 'data')
BRONZE, GOLD, BAD = (os.path.join(DATA, d) for d in ('bronze', 'gold', 'bad_files'))
for d in (BRONZE, GOLD, BAD):
    os.makedirs(d, exist_ok=True)

START, END = pd.Timestamp('2025-01-01'), pd.Timestamp('2026-09-30')
DATES = pd.date_range(START, END, freq='D')
PERIODS = [str(p) for p in pd.period_range('2025-01', '2026-09', freq='M')]
STORY_A_START = pd.Timestamp('2026-07-01')
STORY_A_AIRLINES = ['EK', 'FZ', 'CHR']
SAR_PER_USD = 3.75

# --------------------------------------------------------------------------- helpers
def md5row(df):
    s = df.astype(str).agg('|'.join, axis=1)
    return s.map(lambda x: hashlib.md5(x.encode()).hexdigest()[:12])

def add_audit(df, src, period):
    """Append Bronze audit columns. period = 'YYYY-MM' scalar or per-row series."""
    df = df.copy().reset_index(drop=True)
    if isinstance(period, str):
        period = pd.Series([period] * len(df))
    period = pd.Series(np.asarray(period).astype(str))
    pe = pd.PeriodIndex(period, freq='M')
    ts = pe.to_timestamp(how='end').normalize() + pd.Timedelta(days=1, hours=2)
    df['src_system'] = src
    df['extracted_at'] = ts.strftime('%Y-%m-%d %H:%M:%S')
    df['batch_id'] = (src + '_' + period.str.replace('-', '') + '_001').values
    df['row_hash'] = md5row(df.drop(columns=['src_system', 'extracted_at', 'batch_id']))
    return df

def write(df, folder, name):
    path = os.path.join(folder, name + '.csv')
    df.to_csv(path, index=False, date_format='%Y-%m-%d')
    return path

def dkey(s):
    return pd.to_datetime(s).dt.strftime('%Y%m%d').astype(int)

def season(dates):
    m = pd.DatetimeIndex(dates).month
    base = np.array([0.97, 0.95, 0.96, 1.00, 1.00, 1.04, 1.08, 1.09, 1.00, 1.00, 0.98, 1.03])[m - 1]
    d = pd.DatetimeIndex(dates)
    ramadan = ((d >= '2025-03-01') & (d <= '2025-03-30')) | ((d >= '2026-02-18') & (d <= '2026-03-19'))
    return base * np.where(ramadan, 0.92, 1.0)

def month_index(dates):
    d = pd.DatetimeIndex(dates)
    return (d.year - 2025) * 12 + d.month - 1

# --------------------------------------------------------------------------- reference data
ENTITIES = pd.DataFrame([
    (1, 'ASC',   'Airport Services Co.',         'Airport Services Co. P.J.S.C.',            'XB', 'USD', '1000', 'Airport Services Co PJSC',        'BYP'),
    (2, 'ASCD',  'ASC Development L.L.C.',        'ASC Development L.L.C.',                   'XB', 'USD', '1100', 'ASC Dev LLC',                     'BYP'),
    (3, 'ASCWF', 'ASC Workforce Services L.L.C.', 'ASC Workforce Services L.L.C.',            'XB', 'USD', '1200', 'ASC Workforce',                   'BYP'),
    (4, 'ASCSA', 'ASC SAUDI ARABIA',              'ASC Saudi Arabia LLC',                     'SA', 'SAR', '2000', 'ASC Saudi Arabia',                'DMM'),
], columns=['entity_key', 'entity_code', 'entity_name', 'legal_name', 'country_code', 'local_currency',
            'sap_company_code', 'sf_legal_entity_name', 'home_station'])
ENT_KEY = dict(zip(ENTITIES.entity_code, ENTITIES.entity_key))
ENT_SAP = dict(zip(ENTITIES.entity_code, ENTITIES.sap_company_code))
ENT_SF = dict(zip(ENTITIES.entity_code, ENTITIES.sf_legal_entity_name))

AIRLINES = pd.DataFrame([
    # code icao name alliance alias contract_type margin base_lf catered handled country am
    ('GC',  'GCW', 'Gulfway Airways',        'None',          'Carrier A', 'Per Meal + Turnaround', 0.18, 0.78, True,  True,  'XB', 'N. Faris'),
    ('QR',  'QTR', 'Qatar Airways',          'oneworld',      'Carrier B', 'Per Meal',              0.20, 0.82, True,  True,  'QA', 'S. Karim'),
    ('EY',  'ETD', 'Etihad Airways',         'None',          'Carrier C', 'Per Meal',              0.21, 0.80, True,  True,  'AE', 'S. Karim'),
    ('BA',  'BAW', 'British Airways',        'oneworld',      'Carrier D', 'Per Meal',              0.25, 0.84, True,  True,  'GB', 'R. Menon'),
    ('EK',  'UAE', 'Emirates',               'None',          'Carrier E', 'Per Meal',              0.22, 0.86, True,  True,  'AE', 'R. Menon'),
    ('FZ',  'FDB', 'flydubai',               'None',          'Carrier F', 'Per Meal',              0.15, 0.83, True,  True,  'AE', 'R. Menon'),
    ('TK',  'THY', 'Turkish Airlines',       'Star Alliance', 'Carrier G', 'Per Meal',              0.19, 0.85, True,  True,  'TR', 'N. Faris'),
    ('SV',  'SVA', 'Saudia',                 'SkyTeam',       'Carrier H', 'Per Meal',              0.20, 0.76, True,  True,  'SA', 'S. Karim'),
    ('CHR', 'CHR', 'Charter Operators (pooled)', 'None',      'Carrier I', 'Per Flight (ad hoc)',   0.30, 0.90, True,  True,  'XX', 'N. Faris'),
    ('J9',  'JZR', 'Jazeera Airways',        'None', 'Handled only', 'Turnaround', 0.0, 0.84, False, True, 'KW', 'N. Faris'),
    ('WY',  'OMA', 'Oman Air',               'None', 'Handled only', 'Turnaround', 0.0, 0.78, False, True, 'OM', 'N. Faris'),
    ('KU',  'KAC', 'Kuwait Airways',         'None', 'Handled only', 'Turnaround', 0.0, 0.74, False, True, 'KW', 'N. Faris'),
    ('PK',  'PIA', 'Pakistan International Airlines', 'None', 'Handled only', 'Turnaround', 0.0, 0.80, False, True, 'PK', 'R. Menon'),
    ('IX',  'AXB', 'Air India Express',      'None', 'Handled only', 'Turnaround', 0.0, 0.88, False, True, 'IN', 'R. Menon'),
    ('6E',  'IGO', 'IndiGo',                 'None', 'Handled only', 'Turnaround', 0.0, 0.87, False, True, 'IN', 'R. Menon'),
    ('XY',  'KNE', 'flynas',                 'None', 'Handled only', 'Turnaround', 0.0, 0.82, False, True, 'SA', 'S. Karim'),
    ('G9',  'ABY', 'Air Arabia',             'None', 'Handled only', 'Turnaround', 0.0, 0.85, False, True, 'AE', 'S. Karim'),
    ('MS',  'MSR', 'EgyptAir',               'Star Alliance', 'Handled only', 'Turnaround', 0.0, 0.79, False, True, 'EG', 'N. Faris'),
    ('RJ',  'RJA', 'Royal Jordanian',        'oneworld', 'Handled only', 'Turnaround', 0.0, 0.77, False, True, 'JO', 'N. Faris'),
    ('IA',  'IAW', 'Iraqi Airways',          'None', 'Handled only', 'Turnaround', 0.0, 0.81, False, True, 'IQ', 'N. Faris'),
    ('UL',  'ALK', 'SriLankan Airlines',     'oneworld', 'Handled only', 'Turnaround', 0.0, 0.80, False, True, 'LK', 'R. Menon'),
], columns=['airline_code', 'icao_code', 'airline_name', 'alliance', 'demo_alias', 'contract_type',
            'contract_margin_pct', 'base_load_factor', 'catering_customer', 'handling_customer', 'country_code', 'account_manager'])
AIRLINES.insert(0, 'airline_key', range(1, len(AIRLINES) + 1))
AIRLINES['contract_id'] = ['CTR-' + c + '-2024' for c in AIRLINES.airline_code]
AIRLINES['contract_start'] = '2024-01-01'
AIRLINES['contract_end'] = '2026-12-31'
AL_KEY = dict(zip(AIRLINES.airline_code, AIRLINES.airline_key))
AL_MARGIN = dict(zip(AIRLINES.airline_code, AIRLINES.contract_margin_pct))
AL_LF = dict(zip(AIRLINES.airline_code, AIRLINES.base_load_factor))

STATIONS = pd.DataFrame([
    (1, 'BYP', 'OXBP', 'Bayport International Airport', 'Bayport', 'XB', 'ASC',   'Etc/GMT-3'),
    (2, 'DMM', 'OEDF', 'King Fahd International Airport', 'Dammam', 'SA', 'ASCSA', 'Asia/Riyadh'),
    (3, 'RUH', 'OERK', 'King Khalid International Airport', 'Riyadh', 'SA', 'ASCSA', 'Asia/Riyadh'),
], columns=['station_key', 'station_code', 'icao_code', 'station_name', 'city', 'country_code', 'operating_entity_code', 'timezone'])
ST_KEY = dict(zip(STATIONS.station_code, STATIONS.station_key))

AIRCRAFT = {  # type: (F, J, Y seats, body)
    'A320': (0, 12, 138, 'Narrow'), 'A20N': (0, 12, 144, 'Narrow'), 'A321': (0, 16, 154, 'Narrow'), 'A21N': (0, 16, 160, 'Narrow'),
    'B738': (0, 12, 150, 'Narrow'), 'B738C': (0, 0, 189, 'Narrow'), 'B38M': (0, 10, 164, 'Narrow'),
    'B789': (0, 26, 256, 'Wide'), 'B788': (0, 22, 232, 'Wide'), 'A333': (0, 30, 260, 'Wide'), 'A332': (0, 24, 230, 'Wide'),
    'B77W': (8, 42, 304, 'Wide'), 'A388': (14, 76, 399, 'Wide'),
}

# --------------------------------------------------------------------------- flight schedule
S = []
FLTNO = {'GC': 1, 'EK': 835, 'QR': 1100, 'EY': 371, 'BA': 123, 'TK': 170, 'FZ': 27, 'SV': 760, 'CHR': 9001,
         'J9': 301, 'WY': 601, 'KU': 611, 'PK': 241, 'IX': 471, '6E': 1401, 'XY': 211, 'G9': 103, 'MS': 961, 'RJ': 341, 'IA': 401, 'UL': 221}

def add(al, dest, rg, ac, n=1, days='1234567', station='BYP', entity='ASC', catered=None, origin='BYP', op_prob=1.0):
    for _ in range(n):
        S.append(dict(airline_code=al, flight_number=f'{al}{FLTNO[al]:03d}' if al != 'CHR' else f'CHR{FLTNO[al]}',
                      origin=origin, destination=dest, route_group=rg, aircraft_type=ac, days_of_week=days,
                      station_code=station, service_entity_code=entity,
                      catered_by_asc=bool(AIRLINES.set_index('airline_code').catering_customer[al]) if catered is None else catered,
                      handled_by_asc=True, operate_prob=op_prob))
        FLTNO[al] += 2 if al == 'GC' else 1

# Gulfway Airways - home carrier
for d, ac, n, days in [('LHR', 'B789', 2, '1234567'), ('CDG', 'B789', 1, '1234567'), ('FRA', 'B789', 1, '1234567'), ('MXP', 'A321', 1, '1234567'),
                       ('ATH', 'A321', 1, '1234567'), ('LCA', 'A320', 1, '1234567'), ('IST', 'A321', 1, '1234567'), ('MUC', 'A21N', 1, '1357'),
                       ('MAN', 'B789', 1, '246'), ('GVA', 'A21N', 1, '1357')]:
    add('GC', d, 'Europe', ac, n, days)
for d, ac, n in [('DXB', 'A320', 7), ('DOH', 'A320', 5), ('RUH', 'A320', 3), ('JED', 'A321', 4), ('DMM', 'A320', 2), ('KWI', 'A320', 4),
                 ('MCT', 'A320', 2), ('AUH', 'A320', 2), ('MED', 'A320', 1), ('SHJ', 'A320', 1)]:
    add('GC', d, 'GCC', ac, n)
for d, ac, n, days in [('BOM', 'A321', 3, '1234567'), ('DEL', 'A321', 3, '1234567'), ('COK', 'A320', 1, '1234567'), ('TRV', 'A320', 1, '1234567'),
                       ('HYD', 'A320', 1, '1234567'), ('BLR', 'A320', 1, '1234567'), ('CCJ', 'A320', 1, '1234567'), ('MAA', 'A320', 1, '246'),
                       ('MNL', 'B789', 2, '1234567'), ('BKK', 'B789', 2, '1234567'), ('SGN', 'B789', 1, '135'), ('CMB', 'A321', 1, '1234567'),
                       ('KHI', 'A320', 2, '1234567'), ('LHE', 'A320', 1, '1234567'), ('ISB', 'A320', 1, '1234567'), ('PEW', 'A320', 1, '246'),
                       ('SKT', 'A320', 1, '135'), ('MLE', 'A320', 1, '1234567'), ('DAC', 'A321', 2, '1234567'), ('KTM', 'A320', 1, '1234567'),
                       ('SIN', 'B789', 1, '1234567'), ('CGK', 'B789', 1, '2467'), ('TAS', 'A320', 1, '36')]:
    add('GC', d, 'Asia', ac, n, days)
for d, ac, n, days in [('CAI', 'A321', 2, '1234567'), ('AMM', 'A320', 1, '1234567'), ('BEY', 'A320', 1, '1234567'), ('BGW', 'A320', 2, '1234567'),
                       ('NJF', 'A320', 1, '1234567'), ('EBL', 'A320', 1, '1234567'), ('ADD', 'A320', 1, '135'), ('CMN', 'A321', 1, '246'), ('BSR', 'A320', 1, '1234567')]:
    add('GC', d, 'MEA', ac, n, days)
# foreign catering + handling customers
add('EK', 'DXB', 'GCC', 'A388', 2); add('EK', 'DXB', 'GCC', 'B77W', 4)
add('QR', 'DOH', 'GCC', 'A320', 4); add('QR', 'DOH', 'GCC', 'B789', 2)
add('EY', 'AUH', 'GCC', 'A320', 2); add('EY', 'AUH', 'GCC', 'B789', 1)
add('BA', 'LHR', 'Europe', 'B789', 1); add('BA', 'LHR', 'Europe', 'B77W', 1)
add('TK', 'IST', 'Europe', 'A321', 1); add('TK', 'IST', 'Europe', 'A333', 1)
add('FZ', 'DXB', 'GCC', 'B38M', 4)
add('SV', 'RUH', 'GCC', 'A320', 2); add('SV', 'JED', 'GCC', 'A320', 2)
add('CHR', 'XXX', 'Charter', 'B738C', 2, op_prob=0.65); add('CHR', 'XXX', 'Charter', 'A320', 1, op_prob=0.5)
# handled-only carriers
add('J9', 'KWI', 'GCC', 'A320', 5); add('WY', 'MCT', 'GCC', 'B738', 3); add('KU', 'KWI', 'GCC', 'A320', 3)
add('PK', 'LHE', 'Asia', 'A320', 1); add('PK', 'ISB', 'Asia', 'A320', 1)
add('IX', 'COK', 'Asia', 'B738', 1); add('IX', 'TRV', 'Asia', 'B738', 1); add('IX', 'CNN', 'Asia', 'B738', 1)
add('6E', 'BOM', 'Asia', 'A20N', 1); add('6E', 'DEL', 'Asia', 'A20N', 1); add('6E', 'HYD', 'Asia', 'A20N', 1); add('6E', 'BLR', 'Asia', 'A20N', 1)
add('XY', 'RUH', 'GCC', 'A320', 1); add('XY', 'JED', 'GCC', 'A320', 1); add('XY', 'DMM', 'GCC', 'A320', 1); add('XY', 'MED', 'GCC', 'A320', 1)
add('G9', 'SHJ', 'GCC', 'A320', 4); add('MS', 'CAI', 'MEA', 'B738', 2); add('RJ', 'AMM', 'MEA', 'A320', 1)
add('IA', 'BGW', 'MEA', 'B738', 1); add('IA', 'NJF', 'MEA', 'B738', 1); add('UL', 'CMB', 'Asia', 'A332', 1)
# ASCSA stations (handling GC turnarounds at DMM/RUH; small catering unit at DMM)
add('GC', 'BYP', 'GCC', 'A320', 2, station='DMM', entity='ASCSA', catered=True, origin='DMM')
add('GC', 'BYP', 'GCC', 'A320', 3, station='RUH', entity='ASCSA', catered=False, origin='RUH')
add('CHR', 'XXX', 'Charter', 'B738C', 1, station='DMM', entity='ASCSA', catered=True, origin='DMM', op_prob=0.4)

SCHED = pd.DataFrame(S)
SCHED.insert(0, 'flight_key', range(1, len(SCHED) + 1))
dep_h = rng.integers(0, 24, len(SCHED)); dep_m = rng.choice([0, 5, 10, 15, 20, 25, 30, 35, 40, 45, 50, 55], len(SCHED))
SCHED['sched_dep_local'] = [f'{h:02d}:{m:02d}' for h, m in zip(dep_h, dep_m)]
SCHED['is_night_departure'] = (dep_h >= 22) | (dep_h < 6)
for i, c in enumerate(['seats_f', 'seats_j', 'seats_y']):
    SCHED[c] = SCHED.aircraft_type.map(lambda a: AIRCRAFT[a][i])
SCHED['body_type'] = SCHED.aircraft_type.map(lambda a: AIRCRAFT[a][3])
fee = np.where(SCHED.aircraft_type == 'A388', 2400, np.where(SCHED.body_type == 'Wide', 1500, 620)).astype(float)
fee = np.where(SCHED.airline_code == 'GC', fee * 0.85, fee)
fee = np.where(SCHED.service_entity_code == 'ASCSA', fee * 0.9, fee)
SCHED['turnaround_fee_usd'] = np.round(fee, 2)

# --------------------------------------------------------------------------- flight-day expansion
days_df = pd.DataFrame({'flight_date': DATES, 'dow': DATES.dayofweek + 1})
FD = SCHED.merge(days_df, how='cross')
FD = FD[[str(d) in s for d, s in zip(FD.dow, FD.days_of_week)]]
FD = FD[rng.random(len(FD)) < FD.operate_prob.values].copy()
FD = FD.sort_values(['flight_date', 'flight_key']).reset_index(drop=True)
summer = FD.flight_date.dt.month.isin([6, 7, 8]).values
p_ontime = np.where(summer, 0.84, 0.88)
FD['dep_on_time'] = rng.random(len(FD)) < p_ontime
FD['dep_delay_min'] = np.where(FD.dep_on_time, rng.integers(0, 15, len(FD)), np.round(rng.lognormal(3.4, 0.6, len(FD))).astype(int) + 16)
FD['aircraft_reg'] = [f"{'A9C' if a=='GC' else 'A6' if a in ('EK','FZ','EY','G9') else 'HZ' if a in ('SV','XY') else 'A7' if a=='QR' else 'G' if a=='BA' else 'TC' if a=='TK' else 'XX'}-{c}"
                      for a, c in zip(FD.airline_code, [''.join(rng.choice(list('ABCDEFGHJKLMNPRSTUVWXYZ'), 3)) for _ in range(len(FD))])]
print(f'Flight-days: {len(FD):,} -> avg {len(FD)/len(DATES):.1f} flights/day')

# --------------------------------------------------------------------------- catering (flight x class)
BASE_COST = {'F': (11.0, 5.5, 4.0), 'J': (6.0, 3.0, 2.2), 'Y': (2.2, 1.1, 0.9)}  # food, labour, overhead per meal (USD)
BASE_WASTE = {'F': 0.035, 'J': 0.030, 'Y': 0.022}
CLASS_FILL = {'F': 0.60, 'J': 0.72, 'Y': 1.00}
CL = []
cat = FD[FD.catered_by_asc]
for cls, seatcol in [('F', 'seats_f'), ('J', 'seats_j'), ('Y', 'seats_y')]:
    sub = cat[cat[seatcol] > 0].copy()
    sub['meal_class'] = cls; sub['seats'] = sub[seatcol]
    CL.append(sub)
CL = pd.concat(CL, ignore_index=True).sort_values(['flight_date', 'flight_key', 'meal_class']).reset_index(drop=True)
n = len(CL)
mi = month_index(CL.flight_date)
sea = season(CL.flight_date)
lf = np.clip(CL.airline_code.map(AL_LF).values * sea + rng.normal(0, 0.05, n), 0.45, 0.98)
fill = CL.meal_class.map(CLASS_FILL).values
CL['meals_planned'] = np.maximum(1, np.round(CL.seats.values * lf * fill)).astype(int)
CL['meals_uplifted'] = np.maximum(1, np.round(CL.meals_planned * (1 + rng.normal(0.01, 0.015, n)))).astype(int)
story_a = CL.airline_code.isin(STORY_A_AIRLINES).values & (CL.flight_date >= STORY_A_START).values
eff = np.where(story_a, np.where(CL.flight_date.dt.month.values == 7, 0.6, 1.0), 0.0)
gf_eu = (CL.airline_code == 'GC').values & (CL.route_group == 'Europe').values
gf_eu_f = np.where(gf_eu & (CL.flight_date >= '2026-09-01').values, 2.0, np.where(gf_eu & (CL.flight_date >= '2026-08-01').values, 1.4, 1.0))
al_wf = CL.airline_code.map({'GC': 1.0, 'QR': 0.9, 'EY': 0.95, 'BA': 1.1, 'EK': 1.0, 'FZ': 1.05, 'TK': 1.0, 'SV': 1.15, 'CHR': 1.3}).values
w_rate = np.array([BASE_WASTE[c] for c in CL.meal_class]) * al_wf * (1 + 0.8 * eff) * gf_eu_f
CL['meals_wasted'] = rng.binomial(CL.meals_uplifted.values, np.clip(w_rate, 0, 0.3))
CL['meals_downlifted'] = rng.binomial(CL.meals_uplifted.values, 0.03)
CL['downlift_confirmed_late'] = rng.random(n) < (0.05 + 0.17 * eff)
CL['delivery_on_time'] = rng.random(n) < (0.965 - 0.055 * eff - np.where(gf_eu_f > 1.5, 0.02, 0))
bc = np.array([BASE_COST[c] for c in CL.meal_class])
night = np.where(CL.is_night_departure.values, 1.10, 1.0)
food_u = bc[:, 0] * (1 + 0.0025 * mi) * (1 + 0.12 * eff) * rng.normal(1, 0.03, n)
lab_u = bc[:, 1] * (1 + 0.002 * mi) * night * (1 + 0.22 * eff) * rng.normal(1, 0.02, n)
oh_u = bc[:, 2] * (1 + 0.0015 * mi) * rng.normal(1, 0.01, n)
produced = CL.meals_uplifted.values + CL.meals_wasted.values
CL['food_cost_usd'] = np.round(food_u * produced, 2)
CL['labour_cost_usd'] = np.round(lab_u * produced, 2)
CL['overhead_cost_usd'] = np.round(oh_u * produced, 2)
CL['total_cost_usd'] = CL.food_cost_usd + CL.labour_cost_usd + CL.overhead_cost_usd
contract_year_up = np.where(CL.flight_date.dt.year.values == 2026, 1.03, 1.0)
price_u = bc.sum(axis=1) * (1 + CL.airline_code.map(AL_MARGIN).values) * contract_year_up
CL['revenue_usd'] = np.round(price_u * CL.meals_uplifted.values, 2)
CL['menu_spec_code'] = [f'{a}-{c}-v{3 if s else 2}' for a, c, s in zip(CL.airline_code, CL.meal_class, story_a)]
CL['period'] = CL.flight_date.dt.to_period('M').astype(str)

# DIM_MEAL (menu spec grain)
meal_rows = []
mk = 1
for al in STORY_A_AIRLINES + [a for a in AIRLINES[AIRLINES.catering_customer].airline_code if a not in STORY_A_AIRLINES]:
    for cls in ['F', 'J', 'Y']:
        if not ((CL.airline_code == al) & (CL.meal_class == cls)).any():
            continue
        versions = [(2, '2024-01-01', '2026-06-30' if al in STORY_A_AIRLINES else None, 1.0), (3, '2026-07-01', None, 1.09)] if al in STORY_A_AIRLINES else [(2, '2024-01-01', None, 1.0)]
        for v, eff_from, eff_to, mult in versions:
            f, l, o = BASE_COST[cls]
            meal_rows.append(dict(meal_key=mk, menu_spec_code=f'{al}-{cls}-v{v}', airline_code=al, meal_class=cls,
                                  meal_class_name={'F': 'First', 'J': 'Business', 'Y': 'Economy'}[cls],
                                  meal_type={'F': 'Hot multi-course', 'J': 'Hot tray service', 'Y': 'Hot tray / snack box'}[cls],
                                  spec_version=v, effective_from=eff_from, effective_to=eff_to if eff_to else '9999-12-31',
                                  std_food_cost_usd=round(f * mult, 3), std_labour_cost_usd=round(l, 3), std_overhead_cost_usd=round(o, 3),
                                  spec_change_reason='Premium protein & dessert upgrade requested by airline' if v == 3 else 'Baseline contract specification'))
            mk += 1
DIM_MEAL = pd.DataFrame(meal_rows)
MEAL_KEY = dict(zip(DIM_MEAL.menu_spec_code, DIM_MEAL.meal_key))

# Gold FACT_CATERING_UPLIFT (daily x airline x route_group x class x station)
grp = ['flight_date', 'airline_code', 'route_group', 'meal_class', 'menu_spec_code', 'station_code', 'service_entity_code']
FCU = CL.groupby(grp, as_index=False).agg(flights_catered=('flight_key', 'count'), meals_planned=('meals_planned', 'sum'), meals_uplifted=('meals_uplifted', 'sum'),
                                          meals_downlifted=('meals_downlifted', 'sum'), meals_wasted=('meals_wasted', 'sum'),
                                          late_downlift_confirmations=('downlift_confirmed_late', 'sum'), deliveries_on_time=('delivery_on_time', 'sum'),
                                          food_cost_usd=('food_cost_usd', 'sum'), labour_cost_usd=('labour_cost_usd', 'sum'), overhead_cost_usd=('overhead_cost_usd', 'sum'),
                                          revenue_usd=('revenue_usd', 'sum'))
FCU['deliveries_total'] = FCU.flights_catered
FCU['total_cost_usd'] = (FCU.food_cost_usd + FCU.labour_cost_usd + FCU.overhead_cost_usd).round(2)
for c in ['food_cost_usd', 'labour_cost_usd', 'overhead_cost_usd', 'revenue_usd']:
    FCU[c] = FCU[c].round(2)
FCU_G = pd.DataFrame({
    'catering_uplift_key': range(1, len(FCU) + 1), 'date_key': dkey(FCU.flight_date),
    'entity_key': FCU.service_entity_code.map(ENT_KEY), 'station_key': FCU.station_code.map(ST_KEY), 'airline_key': FCU.airline_code.map(AL_KEY),
    'meal_key': FCU.menu_spec_code.map(MEAL_KEY), 'route_group': FCU.route_group, 'meal_class': FCU.meal_class,
    'flights_catered': FCU.flights_catered, 'meals_planned': FCU.meals_planned, 'meals_uplifted': FCU.meals_uplifted, 'meals_downlifted': FCU.meals_downlifted,
    'meals_wasted': FCU.meals_wasted, 'late_downlift_confirmations': FCU.late_downlift_confirmations.astype(int), 'deliveries_total': FCU.deliveries_total,
    'deliveries_on_time': FCU.deliveries_on_time.astype(int), 'food_cost_usd': FCU.food_cost_usd, 'labour_cost_usd': FCU.labour_cost_usd,
    'overhead_cost_usd': FCU.overhead_cost_usd, 'total_cost_usd': FCU.total_cost_usd, 'revenue_usd': FCU.revenue_usd,
    'src_batch_id': 'CMS_' + FCU.flight_date.dt.strftime('%Y%m') + '_001'})
write(FCU_G, GOLD, 'FACT_CATERING_UPLIFT')

# Bronze CMS: flight-level for Sep-2026 (live window) + daily history Jan-2025..Aug-2026
live = CL[CL.flight_date >= '2026-09-01'].copy()
live_b = pd.DataFrame({
    'UPLIFT_ID': ['UPL' + s for s in (live.flight_date.dt.strftime('%y%m%d') + live.flight_key.astype(str).str.zfill(4) + live.meal_class)],
    'FLT_DATE': live.flight_date.dt.date, 'CARRIER': live.airline_code, 'FLT_NO': live.flight_number, 'DEP_STN': live.station_code, 'DEST': live.destination,
    'AC_TYPE': live.aircraft_type, 'CLASS': live.meal_class, 'MENU_SPEC': live.menu_spec_code, 'MEALS_PLANNED': live.meals_planned, 'MEALS_UPLIFTED': live.meals_uplifted,
    'MEALS_DOWNLIFTED': live.meals_downlifted, 'MEALS_WASTED': live.meals_wasted, 'DOWNLIFT_LATE_FLAG': live.downlift_confirmed_late.map({True: 'Y', False: 'N'}),
    'DELIVERY_ON_TIME_FLAG': live.delivery_on_time.map({True: 'Y', False: 'N'}), 'FOOD_COST': live.food_cost_usd, 'LABOUR_COST': live.labour_cost_usd,
    'OVERHEAD_COST': live.overhead_cost_usd, 'BILL_AMOUNT': live.revenue_usd, 'CURRENCY': 'USD', 'KITCHEN': np.where(live.station_code == 'BYP', 'BYP-MAIN', 'DMM-UNIT')})
# raw-data messiness: lower-case carrier, padded destination, exact duplicates
idx = rng.choice(live_b.index, 40, replace=False); live_b.loc[idx[:20], 'CARRIER'] = live_b.loc[idx[:20], 'CARRIER'].str.lower()
live_b.loc[idx[20:], 'DEST'] = live_b.loc[idx[20:], 'DEST'] + ' '
dups = live_b.sample(26, random_state=SEED)
live_b = pd.concat([live_b, dups], ignore_index=True).sort_values(['FLT_DATE', 'FLT_NO', 'CLASS']).reset_index(drop=True)
write(add_audit(live_b, 'CMS', '2026-09'), BRONZE, 'cms_uplift_flight_class')

hist = FCU[FCU.flight_date < '2026-09-01']
hist_b = pd.DataFrame({'UPLIFT_DATE': hist.flight_date.dt.date, 'CARRIER': hist.airline_code, 'ROUTE_GROUP': hist.route_group, 'CLASS': hist.meal_class,
                       'MENU_SPEC': hist.menu_spec_code, 'DEP_STN': hist.station_code, 'FLIGHTS': hist.flights_catered, 'MEALS_PLANNED': hist.meals_planned,
                       'MEALS_UPLIFTED': hist.meals_uplifted, 'MEALS_DOWNLIFTED': hist.meals_downlifted, 'MEALS_WASTED': hist.meals_wasted,
                       'DOWNLIFT_LATE_CNT': hist.late_downlift_confirmations.astype(int), 'DELIVERIES_ON_TIME': hist.deliveries_on_time.astype(int),
                       'FOOD_COST': hist.food_cost_usd, 'LABOUR_COST': hist.labour_cost_usd, 'OVERHEAD_COST': hist.overhead_cost_usd, 'BILL_AMOUNT': hist.revenue_usd})
write(add_audit(hist_b, 'CMS', hist.flight_date.dt.to_period('M').astype(str)), BRONZE, 'cms_uplift_daily_history')

# CMS production orders (daily x class x kitchen) and menu cost
po = CL.groupby(['flight_date', 'station_code', 'meal_class'], as_index=False).agg(MEALS_ORDERED=('meals_planned', 'sum'), MEALS_PRODUCED=('meals_uplifted', 'sum'), WASTED=('meals_wasted', 'sum'))
po['MEALS_PRODUCED'] = po.MEALS_PRODUCED + po.WASTED
prod_b = pd.DataFrame({'PROD_ORDER_ID': ['PO' + s for s in po.flight_date.dt.strftime('%y%m%d') + po.station_code + po.meal_class], 'PROD_DATE': po.flight_date.dt.date,
                       'KITCHEN': np.where(po.station_code == 'BYP', 'BYP-MAIN', 'DMM-UNIT'), 'CLASS': po.meal_class, 'MEALS_ORDERED': po.MEALS_ORDERED, 'MEALS_PRODUCED': po.MEALS_PRODUCED,
                       'MEALS_WASTED': po.WASTED, 'SHIFT_PLAN': np.where(po.meal_class == 'Y', 'Day+Night', 'Day'), 'STATUS': 'CLOSED'})
write(add_audit(prod_b, 'CMS', po.flight_date.dt.to_period('M').astype(str)), BRONZE, 'cms_production_orders')
menu_b = DIM_MEAL.rename(columns={'menu_spec_code': 'MENU_SPEC', 'airline_code': 'CARRIER', 'meal_class': 'CLASS', 'spec_version': 'VERSION', 'effective_from': 'VALID_FROM', 'effective_to': 'VALID_TO',
                                  'std_food_cost_usd': 'STD_FOOD_COST', 'std_labour_cost_usd': 'STD_LABOUR_COST', 'std_overhead_cost_usd': 'STD_OVERHEAD_COST', 'spec_change_reason': 'CHANGE_REASON'}
                         ).drop(columns=['meal_key', 'meal_class_name', 'meal_type'])
write(add_audit(menu_b, 'CMS', '2026-09'), BRONZE, 'cms_menu_cost')

# --------------------------------------------------------------------------- airline portal orders, SLA events, special meals
daily_al = FCU[FCU.airline_code.isin(AIRLINES[AIRLINES.catering_customer].airline_code)].groupby(['flight_date', 'airline_code'], as_index=False).agg(
    flights=('flights_catered', 'sum'), meals=('meals_uplifted', 'sum'), late=('late_downlift_confirmations', 'sum'))
# flights_catered is per class row; use distinct flights from CL instead
fl_cnt = CL.groupby(['flight_date', 'airline_code']).flight_key.nunique().rename('orders').reset_index()
daily_al = daily_al.merge(fl_cnt, on=['flight_date', 'airline_code'])
n = len(daily_al)
sa = daily_al.airline_code.isin(STORY_A_AIRLINES).values & (daily_al.flight_date >= STORY_A_START).values
daily_al['amended_after_cutoff'] = rng.binomial(daily_al.orders.values, np.where(sa, 0.20, 0.06))
daily_al['special_meal_orders'] = rng.poisson(daily_al.meals.values * 0.018)
daily_al['special_meals_unfulfilled'] = rng.binomial(daily_al.special_meal_orders.values, 0.012)
daily_al['sla_events'] = daily_al.orders.values * 2 + rng.poisson(1.0, n)
daily_al['sla_breaches'] = rng.binomial(daily_al.sla_events.values, np.where(sa, 0.085, 0.03))
daily_al['avg_order_lead_hours'] = np.round(rng.normal(np.where(sa, 11.5, 18.0), 2.0, n), 1)
FAO = pd.DataFrame({'airline_order_key': range(1, n + 1), 'date_key': dkey(daily_al.flight_date), 'airline_key': daily_al.airline_code.map(AL_KEY),
                    'entity_key': 1, 'station_key': 1, 'orders_submitted': daily_al.orders, 'orders_amended_after_cutoff': daily_al.amended_after_cutoff,
                    'special_meal_orders': daily_al.special_meal_orders, 'special_meals_unfulfilled': daily_al.special_meals_unfulfilled, 'sla_events': daily_al.sla_events,
                    'sla_breaches': daily_al.sla_breaches, 'avg_order_lead_hours': daily_al.avg_order_lead_hours, 'src_batch_id': 'PORTAL_' + daily_al.flight_date.dt.strftime('%Y%m') + '_001'})
write(FAO, GOLD, 'FACT_AIRLINE_ORDER')
portal_b = pd.DataFrame({'ORDER_DATE': daily_al.flight_date.dt.date, 'AIRLINE': daily_al.airline_code, 'STATION': 'BYP', 'ORDERS_SUBMITTED': daily_al.orders,
                         'ORDERS_AMENDED_AFTER_CUTOFF': daily_al.amended_after_cutoff, 'SPML_ORDERS': daily_al.special_meal_orders, 'SPML_UNFULFILLED': daily_al.special_meals_unfulfilled,
                         'SLA_EVENTS': daily_al.sla_events, 'SLA_BREACHES': daily_al.sla_breaches, 'AVG_LEAD_HOURS': daily_al.avg_order_lead_hours})
write(add_audit(portal_b, 'PORTAL', daily_al.flight_date.dt.to_period('M').astype(str)), BRONZE, 'portal_orders_daily')

SLA_TYPES = [('Delivery Window', 'Catering delivered >= 45 min before STD', 45), ('Order Cut-off', 'Final meal order received >= 24h before STD', 1440),
             ('Special Meal Fulfilment', 'All SPML on manifest loaded', 100), ('Downlift Confirmation', 'Downlift confirmed <= 2h after ATA', 120), ('Complaint Response', 'Response within 48h', 2880)]
m = 3000
ev_dates = pd.to_datetime(rng.choice(DATES, m))
ev_al = rng.choice(AIRLINES[AIRLINES.catering_customer].airline_code.values, m, p=[0.55, 0.07, 0.04, 0.03, 0.09, 0.07, 0.03, 0.05, 0.07])
ev_t = rng.integers(0, len(SLA_TYPES), m)
sa_ev = np.isin(ev_al, STORY_A_AIRLINES) & (ev_dates >= STORY_A_START)
breached = rng.random(m) < np.where(sa_ev, 0.30, 0.09)
targets = np.array([t[2] for t in SLA_TYPES])[ev_t]
actual = np.where(breached, targets * rng.uniform(1.05, 1.9, m), targets * rng.uniform(0.5, 0.99, m)).round(0)
causes = np.where(~breached, '', rng.choice(['Late downlift confirmation', 'Menu spec change - production delay', 'Night shift staffing gap', 'Airline order amendment after cut-off', 'GSE truck unavailability', 'Ramp congestion'], m, p=[0.3, 0.2, 0.18, 0.15, 0.1, 0.07]))
sla_b = pd.DataFrame({'EVENT_ID': [f'SLA{i:06d}' for i in range(1, m + 1)], 'EVENT_DATE': ev_dates.date, 'AIRLINE': ev_al,
                      'FLT_NO': [rng.choice(SCHED[SCHED.airline_code == a].flight_number.values) for a in ev_al], 'SLA_TYPE': [SLA_TYPES[i][0] for i in ev_t],
                      'SLA_DEFINITION': [SLA_TYPES[i][1] for i in ev_t], 'TARGET_VALUE': targets, 'ACTUAL_VALUE': actual, 'BREACHED': np.where(breached, 'Y', 'N'), 'ROOT_CAUSE': causes}).sort_values('EVENT_DATE').reset_index(drop=True)
write(add_audit(sla_b, 'PORTAL', pd.Series(ev_dates).sort_values().dt.to_period('M').astype(str).values), BRONZE, 'portal_sla_events')

SPML = ['VGML', 'AVML', 'KSML', 'CHML', 'DBML', 'GFML', 'HNML', 'MOML']
sp_rows = []
for p in PERIODS:
    mm = daily_al[daily_al.flight_date.dt.to_period('M').astype(str) == p].groupby('airline_code').special_meal_orders.sum()
    for al, tot in mm.items():
        shares = rng.dirichlet(np.ones(len(SPML)) * 2)
        for code, sh in zip(SPML, shares):
            sp_rows.append(dict(PERIOD=p, AIRLINE=al, SPML_CODE=code, ORDERS=int(round(tot * sh)), UNIT_PRICE_USD=round(rng.uniform(5.5, 9.5), 2)))
spml_b = pd.DataFrame(sp_rows)
write(add_audit(spml_b, 'PORTAL', spml_b.PERIOD), BRONZE, 'portal_special_meals_monthly')

# --------------------------------------------------------------------------- SITA messages (Sep 2026)
sep = FD[FD.flight_date >= '2026-09-16'].copy()
std = pd.to_datetime(sep.flight_date.dt.strftime('%Y-%m-%d') + ' ' + sep.sched_dep_local)
atd = std + pd.to_timedelta(sep.dep_delay_min, unit='m')
mvt = pd.DataFrame({'MSG_ID': ['M' + s for s in sep.flight_date.dt.strftime('%y%m%d') + sep.flight_key.astype(str).str.zfill(4)], 'MSG_TYPE': 'MVT', 'FLT_NO': sep.flight_number, 'FLT_DATE': sep.flight_date.dt.date,
                    'AC_REG': sep.aircraft_reg, 'ORIGIN': sep.origin, 'DEST': sep.destination, 'STATION': sep.station_code, 'STD': std.dt.strftime('%Y-%m-%d %H:%M'), 'ATD': atd.dt.strftime('%Y-%m-%d %H:%M'),
                    'DELAY_MIN': sep.dep_delay_min, 'DELAY_CODE': np.where(sep.dep_on_time, '', rng.choice(['11', '15', '31', '36', '41', '93', '84'], len(sep))),
                    'RAW_TEXT': ['MVT ' + f + '/' + d.strftime('%d') + '.' + r + '.' + s + ' AD' + a.strftime('%H%M') for f, d, r, s, a in zip(sep.flight_number, sep.flight_date, sep.aircraft_reg, sep.station_code, atd)]})
catm = sep[sep.catered_by_asc]
catmsg = pd.DataFrame({'MSG_ID': ['C' + s for s in catm.flight_date.dt.strftime('%y%m%d') + catm.flight_key.astype(str).str.zfill(4)], 'MSG_TYPE': 'CAT', 'FLT_NO': catm.flight_number, 'FLT_DATE': catm.flight_date.dt.date,
                       'AC_REG': catm.aircraft_reg, 'ORIGIN': catm.origin, 'DEST': catm.destination, 'STATION': catm.station_code,
                       'STD': pd.to_datetime(catm.flight_date.dt.strftime('%Y-%m-%d') + ' ' + catm.sched_dep_local).dt.strftime('%Y-%m-%d %H:%M'), 'ATD': '', 'DELAY_MIN': 0, 'DELAY_CODE': '',
                       'RAW_TEXT': ['CAT ' + f + ' UPLIFT CONFIRMED ' + s for f, s in zip(catm.flight_number, catm.station_code)]})
sita_b = pd.concat([mvt, catmsg], ignore_index=True).sort_values(['FLT_DATE', 'FLT_NO', 'MSG_TYPE']).reset_index(drop=True)
write(add_audit(sita_b, 'SITA', '2026-09'), BRONZE, 'sita_messages')

# --------------------------------------------------------------------------- AGG_DAILY_FLIGHTS
adf = FD.groupby(['flight_date', 'airline_code', 'route_group', 'station_code', 'service_entity_code'], as_index=False).agg(
    flights_handled=('flight_key', 'count'), flights_catered=('catered_by_asc', 'sum'), departures_on_time=('dep_on_time', 'sum'), total_delay_min=('dep_delay_min', 'sum'), handling_revenue_usd=('turnaround_fee_usd', 'sum'))
AGG_FL = pd.DataFrame({'date_key': dkey(adf.flight_date), 'entity_key': adf.service_entity_code.map(ENT_KEY), 'station_key': adf.station_code.map(ST_KEY),
                       'airline_key': adf.airline_code.map(AL_KEY), 'route_group': adf.route_group, 'flights_handled': adf.flights_handled, 'flights_catered': adf.flights_catered.astype(int),
                       'departures_on_time': adf.departures_on_time.astype(int), 'total_delay_min': adf.total_delay_min, 'handling_revenue_usd': adf.handling_revenue_usd.round(2)})
write(AGG_FL, GOLD, 'AGG_DAILY_FLIGHTS')

# --------------------------------------------------------------------------- cost centres
CC = [
    ('1101', 'GH Ramp Operations - Day', 'ASC', 'Ground Handling', 'BYP', 170), ('1102', 'GH Ramp Operations - Night', 'ASC', 'Ground Handling', 'BYP', 95),
    ('1103', 'Passenger Services', 'ASC', 'Ground Handling', 'BYP', 120), ('1104', 'Baggage Services', 'ASC', 'Ground Handling', 'BYP', 70),
    ('1105', 'Load Control & Operations', 'ASC', 'Ground Handling', 'BYP', 28), ('1106', 'Aircraft Interior Cleaning', 'ASC', 'Ground Handling', 'BYP', 45),
    ('1107', 'Charter & VIP Handling', 'ASC', 'Ground Handling', 'BYP', 12), ('1108', 'Water & Toilet Services', 'ASC', 'Ground Handling', 'BYP', 14),
    ('1109', 'GH Equipment Pool', 'ASC', 'Ground Handling', 'BYP', 10), ('1110', 'Premier Gold Lounge', 'ASC', 'Ground Handling', 'BYP', 38),
    ('1111', 'Common Use Lounge', 'ASC', 'Ground Handling', 'BYP', 16), ('1112', 'Lost & Found', 'ASC', 'Ground Handling', 'BYP', 8),
    ('1113', 'Flight Operations Support', 'ASC', 'Ground Handling', 'BYP', 14),
    ('1201', 'Catering Hot Kitchen', 'ASC', 'Flight Catering', 'BYP', 75), ('1202', 'Catering Cold Kitchen & Pastry', 'ASC', 'Flight Catering', 'BYP', 48),
    ('1203', 'Bakery', 'ASC', 'Flight Catering', 'BYP', 18), ('1204', 'Catering Dispatch & Transport', 'ASC', 'Flight Catering', 'BYP', 42),
    ('1205', 'Catering Night Shift', 'ASC', 'Flight Catering', 'BYP', 40), ('1206', 'Bonded Stores & Duty Free', 'ASC', 'Flight Catering', 'BYP', 14),
    ('1207', 'Equipment Wash & Tray Set', 'ASC', 'Flight Catering', 'BYP', 36), ('1208', 'Menu Development & QA', 'ASC', 'Flight Catering', 'BYP', 8),
    ('1209', 'Catering Commercial & Billing', 'ASC', 'Flight Catering', 'BYP', 7), ('1210', 'Food Safety & Hygiene', 'ASC', 'Flight Catering', 'BYP', 9),
    ('1211', 'Lounge Catering', 'ASC', 'Flight Catering', 'BYP', 12),
    ('1301', 'Cargo Import', 'ASC', 'Cargo', 'BYP', 40), ('1302', 'Cargo Export', 'ASC', 'Cargo', 'BYP', 36), ('1303', 'Cargo Warehouse & Cool Chain', 'ASC', 'Cargo', 'BYP', 30),
    ('1304', 'Mail & Courier', 'ASC', 'Cargo', 'BYP', 10), ('1305', 'Cargo Sales', 'ASC', 'Cargo', 'BYP', 6),
    ('1401', 'GSE Maintenance Workshop', 'ASC', 'Engineering', 'BYP', 34), ('1402', 'GSE Fleet Management', 'ASC', 'Engineering', 'BYP', 8), ('1403', 'Facilities Engineering', 'ASC', 'Engineering', 'BYP', 14),
    ('1501', 'Executive Office', 'ASC', 'Corporate', 'BYP', 6), ('1502', 'Finance', 'ASC', 'Corporate', 'BYP', 16), ('1503', 'Human Resources', 'ASC', 'Corporate', 'BYP', 12),
    ('1504', 'IT & Digital', 'ASC', 'Corporate', 'BYP', 14), ('1505', 'Procurement & Supply Chain', 'ASC', 'Corporate', 'BYP', 9), ('1506', 'Safety, Security & Quality', 'ASC', 'Corporate', 'BYP', 11),
    ('1507', 'Commercial & Customer', 'ASC', 'Corporate', 'BYP', 8), ('1508', 'Legal & Governance', 'ASC', 'Corporate', 'BYP', 3), ('1509', 'Facilities & Administration', 'ASC', 'Corporate', 'BYP', 10),
    ('1510', 'Internal Audit', 'ASC', 'Corporate', 'BYP', 4),
    ('2101', 'Aviation Training Academy', 'ASCD', 'Training & Development', 'BYP', 18), ('2102', 'Consulting & Projects', 'ASCD', 'Training & Development', 'BYP', 9),
    ('2103', 'Technical Training', 'ASCD', 'Training & Development', 'BYP', 8), ('2104', 'ASCD Administration', 'ASCD', 'Training & Development', 'BYP', 5),
    ('3101', 'Manpower Pool - Ramp', 'ASCWF', 'Manpower', 'BYP', 8), ('3102', 'Manpower Pool - Catering', 'ASCWF', 'Manpower', 'BYP', 6), ('3103', 'Manpower Pool - Cargo', 'ASCWF', 'Manpower', 'BYP', 4),
    ('3104', 'Manpower Pool - Cleaning', 'ASCWF', 'Manpower', 'BYP', 3), ('3105', 'Recruitment & Mobilisation', 'ASCWF', 'Manpower', 'BYP', 14), ('3106', 'Staff Housing & Transport', 'ASCWF', 'Manpower', 'BYP', 16),
    ('3107', 'ASCWF Administration', 'ASCWF', 'Manpower', 'BYP', 9),
    ('4101', 'DMM Ground Handling', 'ASCSA', 'Ground Handling', 'DMM', 38), ('4102', 'DMM Catering Unit', 'ASCSA', 'Flight Catering', 'DMM', 22),
    ('4103', 'RUH Ground Handling', 'ASCSA', 'Ground Handling', 'RUH', 26), ('4104', 'KSA Administration & Finance', 'ASCSA', 'Corporate', 'DMM', 8), ('4105', 'KSA GSE Maintenance', 'ASCSA', 'Engineering', 'DMM', 6),
]
DIM_CC = pd.DataFrame(CC, columns=['cost_center_code', 'cost_center_name', 'entity_code', 'business_unit', 'station_code', 'target_headcount'])
DIM_CC.insert(0, 'cost_center_key', range(1, len(DIM_CC) + 1))
DIM_CC['entity_key'] = DIM_CC.entity_code.map(ENT_KEY)
DIM_CC['station_key'] = DIM_CC.station_code.map(ST_KEY)
DIM_CC['cc_owner'] = rng.choice(['A. Al Dossary', 'M. Al Qahtani', 'K. Al Amri', 'S. Nair', 'J. Santos', 'H. Al Juhani', 'F. Al Baqri', 'R. Menon'], len(DIM_CC))
DIM_CC['is_operational'] = DIM_CC.business_unit.isin(['Ground Handling', 'Flight Catering', 'Cargo', 'Engineering', 'Manpower'])
CC_KEY = dict(zip(DIM_CC.cost_center_code, DIM_CC.cost_center_key))
CC_ENT = dict(zip(DIM_CC.cost_center_code, DIM_CC.entity_code))
CC_BU = dict(zip(DIM_CC.cost_center_code, DIM_CC.business_unit))

# --------------------------------------------------------------------------- GL accounts
GL = [
    ('400100', 'Ground Handling Revenue', 'Revenue', 'Revenue', True, False), ('400200', 'Catering Revenue - Airline Contracts', 'Revenue', 'Revenue', True, False),
    ('400210', 'Catering Revenue - Charter & VIP', 'Revenue', 'Revenue', True, False), ('400300', 'Cargo Handling Revenue', 'Revenue', 'Revenue', True, False),
    ('400400', 'Engineering Services Revenue', 'Revenue', 'Revenue', True, False), ('400500', 'Manpower Services Revenue (Intercompany)', 'Revenue', 'Revenue', True, True),
    ('400600', 'Training & Consulting Revenue', 'Revenue', 'Revenue', True, False), ('400700', 'Lounge Revenue', 'Revenue', 'Revenue', True, False), ('400900', 'Other Operating Income', 'Revenue', 'Revenue', True, False),
    ('500100', 'Food & Beverage Raw Materials', 'COGS', 'Food Cost', True, False), ('500200', 'Packaging & Disposables', 'COGS', 'Food Cost', True, False), ('500300', 'Bonded Stores', 'COGS', 'Food Cost', True, False),
    ('510100', 'Salaries & Wages - Permanent', 'Opex', 'Direct Labour', True, False), ('510200', 'Overtime - Permanent', 'Opex', 'Direct Labour', True, False),
    ('510300', 'Contractor Labour - Regular', 'Opex', 'Contractor Cost', True, False), ('510400', 'Contractor Labour - Overtime', 'Opex', 'Contractor Cost', True, False),
    ('510500', 'Employee Benefits & GOSI', 'Opex', 'Direct Labour', True, False), ('510600', 'Training & Development', 'Opex', 'Admin', True, False),
    ('510700', 'Outsourced Manpower (Intercompany)', 'Opex', 'Contractor Cost', True, True),
    ('520100', 'GSE Fuel & Lubricants', 'Opex', 'Fuel', True, False), ('520200', 'GSE Maintenance - Parts', 'Opex', 'Maintenance', True, False), ('520300', 'GSE Maintenance - External Services', 'Opex', 'Maintenance', True, False),
    ('520400', 'Vehicle Licensing & Insurance', 'Opex', 'Maintenance', True, False), ('530100', 'Utilities', 'Opex', 'Facilities', True, False), ('530200', 'Rent & Concession Fees', 'Opex', 'Facilities', True, False),
    ('530300', 'IT & Telecom', 'Opex', 'Admin', True, False), ('530400', 'Consumables', 'Opex', 'Operations', True, False), ('530500', 'Uniforms & PPE', 'Opex', 'Operations', True, False),
    ('530600', 'Professional Fees', 'Opex', 'Admin', True, False), ('530700', 'Insurance', 'Opex', 'Admin', True, False), ('530800', 'Travel & Accommodation', 'Opex', 'Admin', True, False),
    ('530900', 'Marketing & Events', 'Opex', 'Admin', True, False), ('540100', 'Repairs & Maintenance - Buildings', 'Opex', 'Facilities', True, False), ('550100', 'Other Operating Expenses', 'Opex', 'Operations', True, False),
    ('600100', 'Depreciation - GSE', 'Below EBITDA', 'Depreciation', False, False), ('600200', 'Depreciation - Buildings & Equipment', 'Below EBITDA', 'Depreciation', False, False),
    ('600300', 'Amortisation - Intangibles', 'Below EBITDA', 'Depreciation', False, False), ('700100', 'Finance Costs', 'Below EBITDA', 'Finance', False, False),
    ('700200', 'FX Gain / Loss', 'Below EBITDA', 'Finance', False, False), ('800100', 'Zakat & Taxes', 'Below EBITDA', 'Tax', False, False),
]
DIM_GL = pd.DataFrame(GL, columns=['gl_account', 'gl_description', 'account_class', 'kpi_group', 'is_ebitda', 'is_intercompany'])
DIM_GL.insert(0, 'gl_account_key', range(1, len(DIM_GL) + 1))
DIM_GL['natural_sign'] = np.where(DIM_GL.account_class == 'Revenue', -1, 1)
DIM_GL['statement_line'] = DIM_GL.account_class.map({'Revenue': 'Revenue', 'COGS': 'Cost of Sales', 'Opex': 'Operating Expenses', 'Below EBITDA': 'Below EBITDA'})
GL_KEY = dict(zip(DIM_GL.gl_account, DIM_GL.gl_account_key))

# --------------------------------------------------------------------------- employees & contractors
FIRST = {'XB': (['Ahmed', 'Mohammed', 'Ali', 'Hussain', 'Khalid', 'Yousif', 'Abdulla', 'Hasan', 'Jassim', 'Salman', 'Fahad', 'Isa', 'Ebrahim', 'Hamad', 'Saleh', 'Nasser', 'Rashid', 'Tariq', 'Waleed', 'Omar'],
                ['Fatima', 'Mariam', 'Noora', 'Zainab', 'Aisha', 'Layla', 'Hessa', 'Amal', 'Dana', 'Sara'],
                ['Al Harbi', 'Al Ansi', 'Al Qahtani', 'Al Amri', 'Al Sayed', 'Al Mutairi', 'Al Juhani', 'Al Baqri', 'Al Hashimi', 'Al Shamsi', 'Al Nuaimi', 'Al Rashidi', 'Al Mahmood', 'Al Bakri', 'Al Kaabi', 'Al Majed', 'Al Ansari', 'Al Hamad', 'Al Khatib', 'Al Shaikh']),
         'SA': (['Rajesh', 'Suresh', 'Anil', 'Vijay', 'Manoj', 'Ramesh', 'Santosh', 'Arun', 'Prakash', 'Dinesh', 'Imran', 'Shahid', 'Faisal', 'Zubair', 'Kamran', 'Asif', 'Nazrul', 'Habib', 'Sanjay', 'Deepak'],
                ['Priya', 'Anjali', 'Lakshmi', 'Nadia', 'Farah', 'Sunita'],
                ['Kumar', 'Nair', 'Iyer', 'Menon', 'Sharma', 'Singh', 'Khan', 'Hussain', 'Ahmed', 'Raju', 'Perera', 'Fernando', 'Silva', 'Rahman', 'Islam', 'Uddin', 'Thapa', 'Gurung', 'Varghese', 'Joseph']),
         'PH': (['Jose', 'Juan', 'Mark', 'Ryan', 'Christian', 'Joshua', 'Angelo', 'Paolo', 'Daniel'], ['Maria', 'Ana', 'Jennifer', 'Rose', 'Grace', 'Michelle'],
                ['Santos', 'Reyes', 'Cruz', 'Bautista', 'Garcia', 'Mendoza', 'Flores', 'Dela Cruz', 'Villanueva', 'Ramos'])}
NAT_POOL = {'XB': 'XB', 'IN': 'SA', 'PK': 'SA', 'BD': 'SA', 'LK': 'SA', 'NP': 'SA', 'EG': 'XB', 'PH': 'PH', 'JO': 'XB', 'SA': 'XB'}
TITLES = {'Ground Handling': ['Ramp Agent', 'Senior Ramp Agent', 'Ramp Supervisor', 'Duty Manager', 'Head of Ground Operations'],
          'Flight Catering': ['Kitchen Assistant', 'Commis Chef', 'Chef de Partie', 'Sous Chef', 'Executive Chef'],
          'Cargo': ['Cargo Agent', 'Senior Cargo Agent', 'Cargo Supervisor', 'Cargo Duty Manager', 'Head of Cargo'],
          'Engineering': ['GSE Technician', 'Senior GSE Technician', 'Workshop Supervisor', 'Engineering Manager', 'Head of Engineering'],
          'Corporate': ['Officer', 'Senior Officer', 'Specialist', 'Manager', 'Director'],
          'Training & Development': ['Training Coordinator', 'Instructor', 'Senior Instructor', 'Training Manager', 'Head of Academy'],
          'Manpower': ['Coordinator', 'Senior Coordinator', 'Supervisor', 'Manager', 'General Manager']}
GRADE_SAL = {'G1': (520, 700), 'G2': (700, 1020), 'G3': (1020, 1550), 'G4': (1550, 2800), 'G5': (2800, 5200)}

def make_people(n_people, cc_codes, cc_probs, emp_type, id_prefix, start_id, nat_probs, grade_probs):
    ccs = rng.choice(cc_codes, n_people, p=cc_probs)
    nats = rng.choice(list(nat_probs.keys()), n_people, p=list(nat_probs.values()))
    genders = np.where(rng.random(n_people) < 0.86, 'M', 'F')
    grades = rng.choice(['G1', 'G2', 'G3', 'G4', 'G5'], n_people, p=grade_probs)
    rows = []
    for i in range(n_people):
        pool = FIRST[NAT_POOL[nats[i]]]
        first = rng.choice(pool[0] if genders[i] == 'M' else pool[1]); last = rng.choice(pool[2])
        g = grades[i]; lo, hi = GRADE_SAL[g]
        sal = float(np.round(rng.uniform(lo, hi), 0))
        bu = CC_BU[ccs[i]]
        rows.append(dict(employee_id=f'{id_prefix}{start_id + i:05d}', first_name=first, last_name=last, gender=genders[i], nationality=nats[i],
                         national_id=(f'{rng.integers(100000000, 999999999)}' if nats[i] == 'XB' else f'{nats[i]}{rng.integers(1000000, 9999999)}'),
                         date_of_birth=str((pd.Timestamp('1965-01-01') + pd.Timedelta(days=int(rng.integers(0, 15000)))).date()),
                         cost_center_code=ccs[i], business_unit=bu, job_title=TITLES[bu][int(g[1]) - 1], grade=g, employment_type=emp_type,
                         monthly_salary_usd=sal if emp_type == 'Permanent' else 0.0, housing_allowance_usd=(round(sal * 0.15, 0) if emp_type == 'Permanent' and g >= 'G3' else 0.0),
                         hourly_rate_usd=(round(sal / 192, 3) if emp_type == 'Permanent' else round(rng.uniform(2.2, 3.4), 3)),
                         shift_pattern=('Night' if ccs[i] in ('1102', '1205') else rng.choice(['Day', 'Night', 'Rotating'], p=[0.6, 0.2, 0.2]) if bu in ('Ground Handling', 'Flight Catering', 'Cargo', 'Manpower') else 'Day')))
    return pd.DataFrame(rows)

perm_cc = DIM_CC[DIM_CC.entity_code != 'ASCWF'].copy()
perm_cc = pd.concat([perm_cc, DIM_CC[DIM_CC.entity_code == 'ASCWF']])  # ASCWF staff too
probs = perm_cc.target_headcount / perm_cc.target_headcount.sum()
EMP = make_people(1200, perm_cc.cost_center_code.values, probs.values, 'Permanent', 'E', 10001,
                  {'XB': 0.55, 'IN': 0.20, 'PK': 0.07, 'BD': 0.04, 'LK': 0.03, 'PH': 0.07, 'NP': 0.02, 'EG': 0.02}, [0.42, 0.30, 0.17, 0.08, 0.03])
CON = make_people(400, ['3101', '3102', '3103', '3104'], [0.45, 0.325, 0.15, 0.075], 'Contractor', 'C', 50001,
                  {'XB': 0.25, 'IN': 0.30, 'BD': 0.15, 'NP': 0.12, 'PK': 0.10, 'PH': 0.08}, [0.75, 0.22, 0.03, 0.0, 0.0])
DEPLOY = {'3101': ['1101', '1102', '1104'], '3102': ['1201', '1205', '1207'], '3103': ['1301', '1303'], '3104': ['1106']}
CON['deployed_cost_center_code'] = [rng.choice(DEPLOY[c]) for c in CON.cost_center_code]
AGENCIES = {'3101': 'V100212', '3102': 'V100212', '3103': 'V100377', '3104': 'V100451'}
CON['contractor_vendor_id'] = CON.cost_center_code.map(AGENCIES)
EMP['deployed_cost_center_code'] = EMP.cost_center_code; EMP['contractor_vendor_id'] = ''
PEOPLE = pd.concat([EMP, CON], ignore_index=True)
PEOPLE['entity_code'] = PEOPLE.cost_center_code.map(CC_ENT)
PEOPLE['station_code'] = PEOPLE.cost_center_code.map(dict(zip(DIM_CC.cost_center_code, DIM_CC.station_code)))
hire = pd.Timestamp('2008-01-01') + pd.to_timedelta(rng.integers(0, 18 * 365, len(PEOPLE)), unit='D')
hire = np.where(PEOPLE.employment_type == 'Contractor', pd.Timestamp('2022-01-01') + pd.to_timedelta(rng.integers(0, 1500, len(PEOPLE)), unit='D'), hire)
PEOPLE['hire_date'] = pd.to_datetime(hire).date
term_mask = rng.random(len(PEOPLE)) < 0.06
term = pd.Timestamp('2025-02-01') + pd.to_timedelta(rng.integers(0, 580, len(PEOPLE)), unit='D')
PEOPLE['termination_date'] = np.where(term_mask, pd.to_datetime(term).strftime('%Y-%m-%d'), '')
PEOPLE['employment_status'] = np.where(term_mask, 'Terminated', 'Active')
PEOPLE['work_email'] = (PEOPLE.first_name.str.lower() + '.' + PEOPLE.last_name.str.lower().str.replace(' ', '') + '@asc-demo.example')
PEOPLE['full_name'] = PEOPLE.first_name + ' ' + PEOPLE.last_name
sup = PEOPLE[(PEOPLE.grade >= 'G3') & (PEOPLE.employment_type == 'Permanent')].groupby('cost_center_code').employee_id.first()
PEOPLE['manager_employee_id'] = PEOPLE.cost_center_code.map(sup).fillna('E10001')
PEOPLE['employee_key'] = range(1, len(PEOPLE) + 1)
DIM_EMP = PEOPLE[['employee_key', 'employee_id', 'full_name', 'first_name', 'last_name', 'gender', 'nationality', 'national_id', 'date_of_birth', 'work_email', 'entity_code', 'station_code',
                  'cost_center_code', 'deployed_cost_center_code', 'business_unit', 'job_title', 'grade', 'employment_type', 'contractor_vendor_id', 'shift_pattern', 'hire_date',
                  'termination_date', 'employment_status', 'monthly_salary_usd', 'housing_allowance_usd', 'hourly_rate_usd', 'manager_employee_id']].copy()
DIM_EMP['entity_key'] = DIM_EMP.entity_code.map(ENT_KEY); DIM_EMP['cost_center_key'] = DIM_EMP.cost_center_code.map(CC_KEY)
write(DIM_EMP, GOLD, 'DIM_EMPLOYEE')

# Bronze SuccessFactors employee extract (SF-style column names, SF legal-entity naming, a few duplicates)
sf_emp = EMP.copy()
sf_emp['entity_code'] = sf_emp.cost_center_code.map(CC_ENT)
sf_b = pd.DataFrame({'PERSON_ID_EXTERNAL': sf_emp.employee_id, 'FIRST_NAME': sf_emp.first_name, 'LAST_NAME': sf_emp.last_name, 'GENDER': sf_emp.gender, 'NATIONALITY': sf_emp.nationality,
                     'NATIONAL_ID': sf_emp.national_id, 'DATE_OF_BIRTH': sf_emp.date_of_birth, 'LEGAL_ENTITY': sf_emp.entity_code.map(ENT_SF), 'COST_CENTER': 'CC-' + sf_emp.cost_center_code,
                     'DEPARTMENT': sf_emp.cost_center_code.map(dict(zip(DIM_CC.cost_center_code, DIM_CC.cost_center_name))), 'JOB_TITLE': sf_emp.job_title, 'PAY_GRADE': sf_emp.grade,
                     'EMPLOYMENT_TYPE': 'Regular', 'SHIFT_PATTERN': sf_emp.shift_pattern, 'HIRE_DATE': PEOPLE.hire_date[:len(sf_emp)].values, 'TERMINATION_DATE': PEOPLE.termination_date[:len(sf_emp)].values,
                     'EMP_STATUS': np.where(PEOPLE.termination_date[:len(sf_emp)].values == '', 'A', 'T'), 'BASE_SALARY': sf_emp.monthly_salary_usd, 'HOUSING_ALLOWANCE': sf_emp.housing_allowance_usd,
                     'PAY_CURRENCY': np.where(sf_emp.entity_code == 'ASCSA', 'SAR', 'USD'), 'MANAGER_ID': PEOPLE.manager_employee_id[:len(sf_emp)].values, 'EMAIL': PEOPLE.work_email[:len(sf_emp)].values})
sf_b['BASE_SALARY'] = np.where(sf_b.PAY_CURRENCY == 'SAR', (sf_b.BASE_SALARY * SAR_PER_USD).round(0), sf_b.BASE_SALARY)
sf_b = pd.concat([sf_b, sf_b.sample(8, random_state=SEED)], ignore_index=True).sort_values('PERSON_ID_EXTERNAL').reset_index(drop=True)
write(add_audit(sf_b, 'SF', '2026-09'), BRONZE, 'sf_employee_master')

# --------------------------------------------------------------------------- time entries (permanent) and contractor feed
def active_mask(df_people, period):
    ps = pd.Period(period, 'M'); pstart, pend = ps.start_time, ps.end_time.normalize()
    h = pd.to_datetime(df_people.hire_date); t = pd.to_datetime(df_people.termination_date.replace('', None))
    return (h <= pend) & (t.isna() | (t >= pstart))

OT_CC_FACTOR = {'1101': 1.3, '1102': 1.6, '1104': 1.2, '1201': 1.3, '1205': 1.7, '1204': 1.2, '1301': 1.1, '1303': 1.1, '1106': 1.1, '1401': 1.2}
time_rows = []
for p in PERIODS:
    act = PEOPLE[(PEOPLE.employment_type == 'Permanent') & active_mask(PEOPLE, p)]
    k = len(act); ps = pd.Period(p, 'M')
    seas = 1.3 if ps.month in (6, 7, 8) else 0.85 if (p in ('2025-03', '2026-03')) else 1.0
    leave = rng.poisson(1.6, k) * 8
    reg = 192 - leave
    base_ot = np.where(act.shift_pattern == 'Night', 18, np.where(act.shift_pattern == 'Rotating', 13, 9)) * act.cost_center_code.map(OT_CC_FACTOR).fillna(1.0).values * seas
    base_ot = np.where((act.cost_center_code == '1205') & (p in ('2026-07', '2026-08', '2026-09')), base_ot * 1.5, base_ot)
    base_ot = np.where(act.grade.isin(['G4', 'G5']), 0, base_ot)
    ot = np.maximum(0, rng.normal(base_ot, base_ot * 0.35 + 1)).round(0)
    time_rows.append(pd.DataFrame({'employee_id': act.employee_id.values, 'period': p, 'regular_hours': reg, 'overtime_hours': ot.astype(int), 'leave_hours': leave,
                                   'night_hours': np.where(act.shift_pattern == 'Night', reg, np.where(act.shift_pattern == 'Rotating', reg // 3, 0)),
                                   'hourly_rate': act.hourly_rate_usd.values, 'shift_pattern': act.shift_pattern.values, 'cost_center_code': act.cost_center_code.values}))
TIME = pd.concat(time_rows, ignore_index=True)
TIME['ot_multiplier'] = np.where(TIME.shift_pattern == 'Night', 1.5, 1.25)
TIME['regular_cost_usd'] = (TIME.regular_hours * TIME.hourly_rate).round(2)
TIME['overtime_cost_usd'] = (TIME.overtime_hours * TIME.hourly_rate * TIME.ot_multiplier).round(2)
TIME26 = TIME[TIME.period >= '2026-01']
sf_time_b = pd.DataFrame({'PERSON_ID_EXTERNAL': TIME26.employee_id, 'PERIOD': TIME26.period, 'TIME_TYPE_REGULAR_HRS': TIME26.regular_hours, 'TIME_TYPE_OT_HRS': TIME26.overtime_hours,
                          'TIME_TYPE_NIGHT_HRS': TIME26.night_hours, 'TIME_TYPE_LEAVE_HRS': TIME26.leave_hours, 'OT_MULTIPLIER': TIME26.ot_multiplier, 'APPROVAL_STATUS': 'APPROVED'})
write(add_audit(sf_time_b, 'SF', TIME26.period), BRONZE, 'sf_time_entries_monthly')

con_rows = []
for p in PERIODS:
    act = PEOPLE[(PEOPLE.employment_type == 'Contractor') & active_mask(PEOPLE, p)]
    k = len(act); ps = pd.Period(p, 'M')
    seas = 1.25 if ps.month in (6, 7, 8) else 0.9 if (p in ('2025-03', '2026-03')) else 1.0
    reg = 208 - rng.poisson(0.7, k) * 8
    ot = np.maximum(0, rng.normal(20 * seas, 8, k)).round(0).astype(int)
    con_rows.append(pd.DataFrame({'employee_id': act.employee_id.values, 'period': p, 'regular_hours': reg, 'overtime_hours': ot, 'hourly_rate': act.hourly_rate_usd.values,
                                  'cost_center_code': act.cost_center_code.values, 'deployed_cost_center_code': act.deployed_cost_center_code.values, 'vendor_id': act.contractor_vendor_id.values,
                                  'contractor_name': act.full_name.values, 'shift_pattern': act.shift_pattern.values}))
CONT = pd.concat(con_rows, ignore_index=True)
# story (c): ASCWF contractor overtime Sep-2026 = Aug-2026 + 318 hours exactly
aug = CONT.loc[CONT.period == '2026-08', 'overtime_hours'].sum()
sep_idx = CONT.index[CONT.period == '2026-09']
delta = int(aug + 318 - CONT.loc[sep_idx, 'overtime_hours'].sum())
pick = rng.choice(sep_idx, abs(delta), replace=True)
np.add.at(CONT.overtime_hours.values, pick, np.sign(delta))
CONT['overtime_hours'] = CONT.overtime_hours.clip(lower=0)
# fix any clipping drift
delta2 = int(aug + 318 - CONT.loc[sep_idx, 'overtime_hours'].sum())
if delta2:
    CONT.loc[sep_idx[0], 'overtime_hours'] += delta2
assert CONT.loc[CONT.period == '2026-09', 'overtime_hours'].sum() - aug == 318
CONT['regular_cost_usd'] = (CONT.regular_hours * CONT.hourly_rate).round(2)
CONT['overtime_cost_usd'] = (CONT.overtime_hours * CONT.hourly_rate * 1.25).round(2)
CONT['invoice_no'] = ['INV-' + v[1:] + '-' + p.replace('-', '') + '-' + str(i % 1000).zfill(3) for i, (v, p) in enumerate(zip(CONT.vendor_id, CONT.period))]
inv_date = (pd.PeriodIndex(CONT.period, freq='M').to_timestamp(how='end').normalize() - pd.Timedelta(days=2))
CONT['invoice_date'] = inv_date.strftime('%Y-%m-%d')
def cont_feed(df):
    return pd.DataFrame({'INVOICE_NO': df.invoice_no, 'INVOICE_DATE': df.invoice_date, 'VENDOR_ID': df.vendor_id, 'CONTRACTOR_ID': df.employee_id, 'CONTRACTOR_NAME': df.contractor_name,
                         'POOL_CC': df.cost_center_code, 'DEPLOYED_CC': df.deployed_cost_center_code, 'PERIOD': df.period, 'REG_HOURS': df.regular_hours, 'OT_HOURS': df.overtime_hours,
                         'RATE_USD': df.hourly_rate, 'OT_RATE_USD': (df.hourly_rate * 1.25).round(3), 'AMOUNT_USD': (df.regular_cost_usd + df.overtime_cost_usd).round(2), 'CURRENCY': 'USD'})
feed_hist = cont_feed(CONT[CONT.period <= '2026-08'])
write(add_audit(feed_hist, 'CONTRACTOR', CONT[CONT.period <= '2026-08'].period), BRONZE, 'contractor_feed_invoice_lines')
feed_sep = cont_feed(CONT[CONT.period == '2026-09']).reset_index(drop=True)
feed_sep.to_csv(os.path.join(BAD, 'contractor_feed_2026-09-28_clean.csv'), index=False)
# malformed counterpart: 2 columns missing, bad dates, negative hours, text in numerics, duplicate invoice line
bad = feed_sep.drop(columns=['OT_RATE_USD', 'DEPLOYED_CC']).copy()
bad.loc[3, 'INVOICE_DATE'] = '31/02/2026'; bad.loc[17, 'INVOICE_DATE'] = '2026-13-01'; bad.loc[41, 'INVOICE_DATE'] = 'N/A'
bad.loc[8, 'OT_HOURS'] = -12; bad.loc[22, 'REG_HOURS'] = -208; bad.loc[55, 'OT_HOURS'] = 612
bad = bad.astype(object); bad.loc[30, 'AMOUNT_USD'] = 'TBC'; bad.loc[61, 'RATE_USD'] = 'USD 2.75'
bad.loc[70, 'CONTRACTOR_ID'] = ''; bad.loc[75, 'VENDOR_ID'] = 'V1OO212'
bad = pd.concat([bad, bad.iloc[[5, 5, 9]]], ignore_index=True)
bad.to_csv(os.path.join(BAD, 'contractor_feed_2026-09-28_malformed.csv'), index=False)

# Gold FACT_LABOUR_COST (monthly x cost centre x deployed cc x employment type x shift)
lab_p = TIME.assign(employment_type='Permanent', deployed_cost_center_code=TIME.cost_center_code)[['period', 'cost_center_code', 'deployed_cost_center_code', 'employment_type', 'shift_pattern', 'employee_id', 'regular_hours', 'overtime_hours', 'night_hours', 'leave_hours', 'regular_cost_usd', 'overtime_cost_usd']]
lab_c = CONT.assign(employment_type='Contractor', night_hours=np.where(CONT.shift_pattern == 'Night', CONT.regular_hours, 0), leave_hours=0)[lab_p.columns]
LAB = pd.concat([lab_p, lab_c]).groupby(['period', 'cost_center_code', 'deployed_cost_center_code', 'employment_type', 'shift_pattern'], as_index=False).agg(
    headcount=('employee_id', 'nunique'), regular_hours=('regular_hours', 'sum'), overtime_hours=('overtime_hours', 'sum'), night_hours=('night_hours', 'sum'), leave_hours=('leave_hours', 'sum'),
    regular_cost_usd=('regular_cost_usd', 'sum'), overtime_cost_usd=('overtime_cost_usd', 'sum'))
LAB['benefits_cost_usd'] = np.where(LAB.employment_type == 'Permanent', (LAB.regular_cost_usd * 0.20).round(2), 0.0)
LAB['total_cost_usd'] = (LAB.regular_cost_usd + LAB.overtime_cost_usd + LAB.benefits_cost_usd).round(2)
pend = pd.PeriodIndex(LAB.period, freq='M').to_timestamp(how='end').normalize()
FLC = pd.DataFrame({'labour_cost_key': range(1, len(LAB) + 1), 'fiscal_period': LAB.period, 'date_key': pend.strftime('%Y%m%d').astype(int), 'entity_key': LAB.cost_center_code.map(CC_ENT).map(ENT_KEY),
                    'cost_center_key': LAB.cost_center_code.map(CC_KEY), 'deployed_cost_center_key': LAB.deployed_cost_center_code.map(CC_KEY), 'employment_type': LAB.employment_type, 'shift_pattern': LAB.shift_pattern,
                    'headcount': LAB.headcount, 'regular_hours': LAB.regular_hours, 'overtime_hours': LAB.overtime_hours, 'night_hours': LAB.night_hours, 'leave_hours': LAB.leave_hours,
                    'regular_cost_usd': LAB.regular_cost_usd.round(2), 'overtime_cost_usd': LAB.overtime_cost_usd.round(2), 'benefits_cost_usd': LAB.benefits_cost_usd, 'total_cost_usd': LAB.total_cost_usd,
                    'src_batch_id': np.where(LAB.employment_type == 'Permanent', 'SF_', 'CONTRACTOR_') + LAB.period.str.replace('-', '') + '_001'})
write(FLC, GOLD, 'FACT_LABOUR_COST')

# --------------------------------------------------------------------------- assets (SCD2), work orders, meters
ASSET_TYPES = {'T': ('Aircraft Tug (Pushback)', 'TLD', 'TPX-200', 45, 0.35, 380), 'BL': ('Belt Loader', 'TLD', 'NBL-S', 35, 0.30, 300), 'HL': ('High Loader', 'Trepel', 'Champ 350', 60, 0.45, 250),
               'GPU': ('Ground Power Unit', 'ITW GSE', '2400 Power Coil', 30, 0.25, 420), 'CT': ('Catering Hi-Lift Truck', 'Mallaghan', 'CT6000', 55, 0.40, 330)}
asset_ids = [f'T-{i}' for i in range(101, 113)] + ['T-114'] + [f'BL-{i}' for i in range(201, 210)] + [f'HL-{i}' for i in range(301, 307)] + [f'GPU-{i}' for i in range(401, 407)] + [f'CT-{i}' for i in range(501, 507)]
assets = []
for a in asset_ids:
    t = a.split('-')[0]; name, make, model, dt_rate, fail_rate, hrs = ASSET_TYPES[t]
    yr = int(rng.integers(2014, 2024))
    cc = {'T': '1109', 'BL': '1109', 'HL': '1109', 'GPU': '1109', 'CT': '1204'}[t]
    station = 'BYP'
    if a in ('T-111', 'T-112', 'BL-209', 'GPU-406'):
        station, cc = 'DMM', '4101'
    assets.append(dict(asset_id=a, asset_type=name, asset_class=t, make=make, model=model, year_of_manufacture=yr, acquisition_cost_usd=float(np.round(rng.uniform(28000, 165000), 0)),
                       downtime_rate_usd_per_hr=dt_rate, failure_rate_per_month=fail_rate, monthly_op_hours=hrs, cost_center_code=cc, station_code=station,
                       entity_code='ASCSA' if station == 'DMM' else 'ASC', status='Active', criticality='High' if t in ('T', 'HL') else 'Medium', effective_from='2024-01-01'))
AS = pd.DataFrame(assets)
# SCD2 versions
scd = []
for _, r in AS.iterrows():
    versions = [dict(r)]
    if r.asset_id == 'T-114':
        v2 = dict(r); v2.update(cost_center_code='1102', effective_from='2026-05-01', status='Active'); versions.append(v2)
        v3 = dict(r); v3.update(cost_center_code='1102', effective_from='2026-08-20', status='Watch List - Hydraulic'); versions.append(v3)
    elif r.asset_id in ('T-104', 'BL-203', 'HL-302'):
        v2 = dict(r); v2.update(status='Under Major Overhaul', effective_from='2025-09-15'); versions.append(v2)
        v3 = dict(r); v3.update(status='Active', effective_from='2025-11-10'); versions.append(v3)
    elif r.asset_id in ('GPU-403', 'CT-505'):
        v2 = dict(r); v2.update(cost_center_code='1107' if r.asset_id == 'GPU-403' else '1211', effective_from='2026-02-01'); versions.append(v2)
    elif r.asset_id == 'T-111':
        v2 = dict(r); v2.update(station_code='RUH', cost_center_code='4103', effective_from='2026-03-01'); versions.append(v2)
    for i, v in enumerate(versions):
        v['effective_to'] = versions[i + 1]['effective_from'] if i + 1 < len(versions) else '9999-12-31'
        v['is_current'] = i + 1 == len(versions); v['version_no'] = i + 1
        scd.append(v)
DIM_ASSET = pd.DataFrame(scd)
DIM_ASSET.insert(0, 'asset_key', range(1, len(DIM_ASSET) + 1))
DIM_ASSET['entity_key'] = DIM_ASSET.entity_code.map(ENT_KEY); DIM_ASSET['station_key'] = DIM_ASSET.station_code.map(ST_KEY); DIM_ASSET['cost_center_key'] = DIM_ASSET.cost_center_code.map(CC_KEY)
write(DIM_ASSET.drop(columns=['failure_rate_per_month', 'monthly_op_hours']), GOLD, 'DIM_ASSET')
def asset_key_at(asset_id, d):
    v = DIM_ASSET[(DIM_ASSET.asset_id == asset_id) & (pd.to_datetime(DIM_ASSET.effective_from) <= d) & (pd.to_datetime(DIM_ASSET.effective_to) > d)]
    return int(v.asset_key.iloc[0])

mx_assets = DIM_ASSET[DIM_ASSET.is_current]
mx_b = pd.DataFrame({'ASSETNUM': mx_assets.asset_id, 'DESCRIPTION': mx_assets.asset_type + ' ' + mx_assets.make + ' ' + mx_assets.model, 'ASSETTYPE': mx_assets.asset_class, 'MANUFACTURER': mx_assets.make, 'MODEL': mx_assets.model,
                     'INSTALLDATE': mx_assets.year_of_manufacture.astype(str) + '-06-01', 'PURCHASEPRICE': mx_assets.acquisition_cost_usd, 'SITEID': mx_assets.station_code + '-GSE', 'LOCATION': mx_assets.station_code + '-RAMP',
                     'GLACCOUNT': 'CC-' + mx_assets.cost_center_code, 'STATUS': mx_assets.status.str.upper(), 'PRIORITY': np.where(mx_assets.criticality == 'High', 1, 2), 'CHANGEDATE': np.where(mx_assets.asset_id == 'T-114', '2026-08-20', '2026-01-05')})
write(add_audit(mx_b, 'MAXIMO', '2026-09'), BRONZE, 'maximo_assets')

FAULTS = {'T': (['HYD-01', 'HYD-02', 'ENG-01', 'TRN-01', 'BRK-01', 'ELE-01', 'TYR-01'], [0.12, 0.08, 0.2, 0.15, 0.15, 0.2, 0.1]), 'BL': (['BLT-01', 'HYD-01', 'ELE-01', 'ENG-01', 'TYR-01'], [0.3, 0.15, 0.25, 0.2, 0.1]),
          'HL': (['HYD-01', 'HYD-02', 'ELE-01', 'PLT-01', 'ENG-01'], [0.3, 0.15, 0.25, 0.15, 0.15]), 'GPU': (['ELE-01', 'ELE-02', 'ENG-01', 'CAB-01'], [0.35, 0.25, 0.25, 0.15]), 'CT': (['HYD-01', 'LFT-01', 'ELE-01', 'ENG-01', 'BRK-01', 'REF-01'], [0.25, 0.15, 0.2, 0.15, 0.1, 0.15])}
FAULT_DESC = {'HYD-01': 'Hydraulic leak - hose/fitting', 'HYD-02': 'Hydraulic pressure loss - pump', 'ENG-01': 'Engine fault / no start', 'TRN-01': 'Transmission fault', 'BRK-01': 'Brake system fault', 'ELE-01': 'Electrical fault - wiring', 'ELE-02': 'Electrical fault - output regulation',
              'TYR-01': 'Tyre damage', 'BLT-01': 'Belt tracking / tear', 'PLT-01': 'Platform alignment', 'CAB-01': 'Cable/connector damage', 'LFT-01': 'Lift scissor fault', 'REF-01': 'Refrigeration unit fault', 'PM-00': 'Scheduled preventive maintenance'}
wo_rows = []
T114_HYD = {'2026-03': 1, '2026-04': 1, '2026-05': 1, '2026-06': 2, '2026-07': 2, '2026-08': 3, '2026-09': 5}
wo_seq = 1
for _, a in AS.iterrows():
    t = a.asset_class; codes, probs = FAULTS[t]
    for p in PERIODS:
        ps = pd.Period(p, 'M'); ndays = ps.days_in_month
        # preventive
        d = ps.start_time + pd.Timedelta(days=int(rng.integers(0, ndays)))
        hrs = float(np.round(rng.uniform(2, 4), 1))
        wo_rows.append(dict(asset_id=a.asset_id, wo_date=d, wo_type='PM', fault_code='PM-00', priority=3, downtime_hours=hrs, repair_hours=hrs, parts_cost=float(np.round(rng.uniform(40, 220), 2)), labour_hours=round(hrs * 1.5, 1)))
        # corrective
        n_cm = rng.poisson(a.failure_rate_per_month)
        extra = T114_HYD.get(p, 0) if a.asset_id == 'T-114' else 0
        for i in range(n_cm + extra):
            is_story = a.asset_id == 'T-114' and i >= n_cm
            d = ps.start_time + pd.Timedelta(days=int(rng.integers(0, ndays)), hours=int(rng.integers(0, 24)))
            code = rng.choice(['HYD-01', 'HYD-02'], p=[0.6, 0.4]) if is_story else rng.choice(codes, p=probs)
            esc = 1 + 0.35 * list(T114_HYD).index(p) if is_story else 1.0
            dt = float(np.round(rng.lognormal(1.7, 0.5) * esc, 1))
            wo_rows.append(dict(asset_id=a.asset_id, wo_date=d, wo_type='CM', fault_code=code, priority=1 if code.startswith('HYD') or a.criticality == 'High' else 2, downtime_hours=dt, repair_hours=float(np.round(dt * rng.uniform(0.6, 0.95), 1)),
                                parts_cost=float(np.round(rng.lognormal(5.0, 0.8) * esc, 2)), labour_hours=float(np.round(dt * rng.uniform(0.8, 1.6), 1))))
WO = pd.DataFrame(wo_rows).sort_values('wo_date').reset_index(drop=True)
WO['wo_id'] = [f'WO{2500000 + i}' for i in range(len(WO))]
WO['reported_ts'] = WO.wo_date; WO['start_ts'] = WO.wo_date + pd.to_timedelta(rng.uniform(0.2, 3, len(WO)), unit='h')
WO['finish_ts'] = WO.start_ts + pd.to_timedelta(WO.repair_hours, unit='h')
WO['labour_cost_usd'] = (WO.labour_hours * 9.5).round(2)
rate = WO.asset_id.str.split('-').str[0].map({k: v[3] for k, v in ASSET_TYPES.items()})
WO['downtime_cost_usd'] = (WO.downtime_hours * rate).round(2)
WO['status'] = 'COMP'
WO['technician_id'] = rng.choice(PEOPLE[PEOPLE.cost_center_code.isin(['1401', '4105'])].employee_id.values, len(WO))
WO['asset_key'] = [asset_key_at(a, d) for a, d in zip(WO.asset_id, WO.wo_date)]
FWO = pd.DataFrame({'work_order_key': range(1, len(WO) + 1), 'wo_id': WO.wo_id, 'asset_key': WO.asset_key, 'asset_id': WO.asset_id, 'date_key': dkey(WO.wo_date),
                    'entity_key': WO.asset_key.map(dict(zip(DIM_ASSET.asset_key, DIM_ASSET.entity_key))), 'station_key': WO.asset_key.map(dict(zip(DIM_ASSET.asset_key, DIM_ASSET.station_key))),
                    'cost_center_key': WO.asset_key.map(dict(zip(DIM_ASSET.asset_key, DIM_ASSET.cost_center_key))), 'wo_type': WO.wo_type, 'fault_code': WO.fault_code, 'fault_description': WO.fault_code.map(FAULT_DESC),
                    'priority': WO.priority, 'reported_ts': WO.reported_ts.dt.strftime('%Y-%m-%d %H:%M:%S'), 'start_ts': WO.start_ts.dt.strftime('%Y-%m-%d %H:%M:%S'), 'finish_ts': WO.finish_ts.dt.strftime('%Y-%m-%d %H:%M:%S'),
                    'downtime_hours': WO.downtime_hours, 'repair_hours': WO.repair_hours, 'labour_hours': WO.labour_hours, 'parts_cost_usd': WO.parts_cost, 'labour_cost_usd': WO.labour_cost_usd,
                    'downtime_cost_usd': WO.downtime_cost_usd, 'is_failure': WO.wo_type == 'CM', 'status': WO.status, 'technician_id': WO.technician_id, 'src_batch_id': 'MAXIMO_' + WO.wo_date.dt.strftime('%Y%m') + '_001'})
write(FWO, GOLD, 'FACT_WORK_ORDER')
mxwo_b = pd.DataFrame({'WONUM': WO.wo_id, 'ASSETNUM': WO.asset_id, 'SITEID': WO.asset_key.map(dict(zip(DIM_ASSET.asset_key, DIM_ASSET.station_code))) + '-GSE', 'WORKTYPE': WO.wo_type, 'FAILURECODE': WO.fault_code,
                       'PROBLEMCODE': WO.fault_code.map(FAULT_DESC), 'WOPRIORITY': WO.priority, 'REPORTDATE': WO.reported_ts.dt.strftime('%Y-%m-%d %H:%M:%S'), 'ACTSTART': WO.start_ts.dt.strftime('%Y-%m-%d %H:%M:%S'),
                       'ACTFINISH': WO.finish_ts.dt.strftime('%Y-%m-%d %H:%M:%S'), 'DOWNTIME_HRS': WO.downtime_hours, 'ACTLABHRS': WO.labour_hours, 'ACTMATCOST': WO.parts_cost, 'ACTLABCOST': WO.labour_cost_usd,
                       'STATUS': WO.status, 'LEAD': WO.technician_id, 'GLACCOUNT': 'CC-' + WO.asset_key.map(dict(zip(DIM_ASSET.asset_key, DIM_ASSET.cost_center_code)))})
write(add_audit(mxwo_b, 'MAXIMO', WO.wo_date.dt.to_period('M').astype(str)), BRONZE, 'maximo_work_orders')
met = []
for _, a in AS.iterrows():
    for p in PERIODS:
        h = a.monthly_op_hours * (1.18 if a.asset_id == 'T-114' and p >= '2026-05' else 1.0) * rng.normal(1, 0.08)
        met.append(dict(ASSETNUM=a.asset_id, METERNAME='RUNHOURS', PERIOD=p, READING_HRS=round(float(h), 1), READING_DATE=str(pd.Period(p, 'M').end_time.date())))
met_b = pd.DataFrame(met)
write(add_audit(met_b, 'MAXIMO', met_b.PERIOD), BRONZE, 'maximo_meter_readings')
AGG_ASSET = met_b.merge(WO[WO.wo_type == 'CM'].assign(PERIOD=WO.wo_date.dt.to_period('M').astype(str)).groupby(['asset_id', 'PERIOD']).agg(failures=('wo_id', 'count'), repair_hours=('repair_hours', 'sum'), downtime_hours=('downtime_hours', 'sum'), downtime_cost_usd=('downtime_cost_usd', 'sum'), hyd_faults=('fault_code', lambda s: int(s.str.startswith('HYD').sum()))).reset_index().rename(columns={'asset_id': 'ASSETNUM'}),
                        on=['ASSETNUM', 'PERIOD'], how='left').fillna({'failures': 0, 'repair_hours': 0, 'downtime_hours': 0, 'downtime_cost_usd': 0, 'hyd_faults': 0})
AGG_ASSET = pd.DataFrame({'fiscal_period': AGG_ASSET.PERIOD, 'asset_id': AGG_ASSET.ASSETNUM, 'asset_key': [asset_key_at(a, pd.Period(p, 'M').end_time.normalize()) for a, p in zip(AGG_ASSET.ASSETNUM, AGG_ASSET.PERIOD)],
                          'operating_hours': AGG_ASSET.READING_HRS, 'failures': AGG_ASSET.failures.astype(int), 'hydraulic_faults': AGG_ASSET.hyd_faults.astype(int), 'repair_hours': AGG_ASSET.repair_hours.round(1),
                          'downtime_hours': AGG_ASSET.downtime_hours.round(1), 'downtime_cost_usd': AGG_ASSET.downtime_cost_usd.round(2)})
AGG_ASSET['mtbf_hours'] = np.where(AGG_ASSET.failures > 0, (AGG_ASSET.operating_hours / AGG_ASSET.failures).round(1), np.nan)
AGG_ASSET['mttr_hours'] = np.where(AGG_ASSET.failures > 0, (AGG_ASSET.repair_hours / AGG_ASSET.failures).round(2), np.nan)
write(AGG_ASSET, GOLD, 'AGG_MONTHLY_ASSET_RELIABILITY')

# --------------------------------------------------------------------------- vendors (MDM), POs, Ariba
PREFIX = ['Al Jazeera', 'Gulf', 'Bayport', 'Coastal', 'Harbour', 'Eastline', 'Al Noor', 'Al Fajr', 'Summit', 'Crescent', 'Arabian', 'Seaside', 'Northgate', 'Westbay', 'Highland', 'Southport', 'Silverline', 'Bluewater', 'Meridian', 'Atlas', 'Premier', 'Pearl', 'Alnoor', 'Unity', 'Horizon', 'Sandline']
CATS = [('Food Supplies', '500100'), ('Fresh Produce', '500100'), ('Poultry & Meats', '500100'), ('Seafood', '500100'), ('Dairy', '500100'), ('Bakery Supplies', '500100'), ('Packaging', '500200'), ('Disposables', '500200'),
        ('Laundry Services', '550100'), ('GSE Parts', '520200'), ('Hydraulics', '520200'), ('Tyres & Batteries', '520200'), ('Fuel Services', '520100'), ('Manpower', '510300'), ('Cleaning Services', '550100'), ('Uniforms', '530500'),
        ('IT Solutions', '530300'), ('Telecom', '530300'), ('Insurance', '530700'), ('Consulting', '530600'), ('Facilities Management', '540100'), ('Pest Control', '550100'), ('Waste Management', '550100'), ('Logistics', '550100'), ('Printing', '530400'), ('Security Services', '550100'), ('Engineering Services', '520300')]
SUFFIX = ['L.L.C.', 'P.J.S.C.', 'Co. L.L.C.', 'S.P.C.', 'Est.']
vend = []
used = set()
vid = 100501
while len(vend) < 80:
    pfx = rng.choice(PREFIX); cat, gl = CATS[int(rng.integers(0, len(CATS)))]; sfx = rng.choice(SUFFIX)
    name = f'{pfx} {cat} {sfx}'
    if name in used:
        continue
    used.add(name)
    vend.append(dict(vendor_id=f'V{vid}', vendor_name=name, category=cat, default_gl=gl, cr_number=f'CR-{rng.integers(10000, 99999)}', iban=f'BH{rng.integers(10, 99)}BMAG{rng.integers(10**13, 10**14 - 1)}',
                     country='XB' if rng.random() < 0.85 else rng.choice(['SA', 'AE', 'GB', 'IN']), payment_terms=rng.choice(['NET30', 'NET45', 'NET60']), created_by='SAP_MIGRATION', created_on='2019-04-15', source='SAP'))
    vid += int(rng.integers(1, 9))
# force the 3 manpower agencies used by contractor feed
for i, (vidx, nm) in enumerate([('V100212', 'Gulf Manpower Services L.L.C.'), ('V100377', 'Eastline Manpower & Recruitment Co. L.L.C.'), ('V100451', 'Coastal Manpower Supply S.P.C.')]):
    vend[i].update(vendor_id=vidx, vendor_name=nm, category='Manpower', default_gl='510300')
VEND = pd.DataFrame(vend)
def variant(name):
    choice = rng.integers(0, 5)
    if choice == 0: return name.upper().replace('.', '')
    if choice == 1: return name.replace('L.L.C.', 'LLC').replace('P.J.S.C.', 'PJSC').replace('Co.', 'Company')
    if choice == 2: return name.replace('&', 'and') + ' '
    if choice == 3: return name.replace('.', '').replace('  ', ' ').upper()
    return name.replace(' (c)', '(C)').replace('S.P.C.', 'SPC')
dup_src = VEND.sample(17, random_state=SEED)
dups = dup_src.copy()
dups['vendor_id'] = [f'V3{int(rng.integers(10000, 99999))}' for _ in range(17)]
dups['vendor_name'] = [variant(n) for n in dup_src.vendor_name]
dups['created_by'] = 'ARIBA_SYNC'; dups['created_on'] = '2024-11-02'; dups['source'] = 'ARIBA'
dups['payment_terms'] = np.where(rng.random(17) < 0.4, 'NET30', dups.payment_terms)
VEND_RAW = pd.concat([VEND, dups], ignore_index=True).sort_values('vendor_id').reset_index(drop=True)
DUP_MAP = dict(zip(dups.vendor_id, dup_src.vendor_id))
vm_b = pd.DataFrame({'LIFNR': VEND_RAW.vendor_id, 'NAME1': VEND_RAW.vendor_name, 'LAND1': VEND_RAW.country, 'STCD1': VEND_RAW.cr_number, 'IBAN': VEND_RAW.iban, 'ZTERM': VEND_RAW.payment_terms, 'KTOKK': 'KRED',
                     'CATEGORY': VEND_RAW.category, 'ERNAM': VEND_RAW.created_by, 'ERDAT': VEND_RAW.created_on, 'LOEVM': ''})
write(add_audit(vm_b, 'SAP', '2026-09'), BRONZE, 'sap_vendor_master')
ar_sup = VEND_RAW[VEND_RAW.source == 'ARIBA'].copy()
ar_sup = pd.concat([ar_sup, VEND.sample(60, random_state=7)], ignore_index=True)
ar_b = pd.DataFrame({'SUPPLIER_ID': 'ARB-' + ar_sup.vendor_id.str[1:], 'ERP_VENDOR_ID': ar_sup.vendor_id, 'SUPPLIER_NAME': ar_sup.vendor_name, 'COMMODITY': ar_sup.category, 'TAX_ID': ar_sup.cr_number,
                     'BANK_ACCOUNT': ar_sup.iban, 'COUNTRY': ar_sup.country, 'REGISTRATION_STATUS': 'Registered', 'RISK_SCORE': rng.integers(1, 6, len(ar_sup))})
write(add_audit(ar_b, 'ARIBA', '2026-09'), BRONZE, 'ariba_suppliers')
DIM_VENDOR = VEND.copy()
DIM_VENDOR.insert(0, 'vendor_key', range(1, len(DIM_VENDOR) + 1))
DIM_VENDOR = DIM_VENDOR.rename(columns={'vendor_id': 'golden_vendor_id', 'vendor_name': 'golden_vendor_name'})
DIM_VENDOR['duplicate_source_ids'] = DIM_VENDOR.golden_vendor_id.map({v: k for k, v in DUP_MAP.items()}).fillna('')
DIM_VENDOR['match_rule'] = np.where(DIM_VENDOR.duplicate_source_ids != '', 'CR_NUMBER+IBAN exact; normalised name', 'Single source record')
write(DIM_VENDOR.drop(columns=['created_by', 'created_on', 'source']), GOLD, 'DIM_VENDOR')
VKEY = dict(zip(DIM_VENDOR.golden_vendor_id, DIM_VENDOR.vendor_key))

npo = 2200
po_dates = pd.to_datetime(rng.choice(DATES, npo))
po_v = VEND_RAW.sample(npo, replace=True, random_state=SEED).reset_index(drop=True)
po_cc = rng.choice(DIM_CC.cost_center_code.values, npo, p=(DIM_CC.target_headcount / DIM_CC.target_headcount.sum()).values)
amt = np.round(rng.lognormal(7.2, 1.1, npo), 2)
PO = pd.DataFrame({'EBELN': [f'45{i:08d}' for i in range(1, npo + 1)], 'EBELP': '00010', 'BEDAT': po_dates.date, 'LIFNR': po_v.vendor_id, 'NAME1': po_v.vendor_name, 'BUKRS': pd.Series(po_cc).map(CC_ENT).map(ENT_SAP).values,
                   'KOSTL': po_cc, 'SAKTO': po_v.default_gl, 'MATKL': po_v.category, 'TXZ01': po_v.category + ' - ' + rng.choice(['monthly supply', 'spot purchase', 'service call-off', 'annual contract call-off'], npo),
                   'MENGE': rng.integers(1, 500, npo), 'NETWR': amt, 'WAERS': rng.choice(['USD', 'USD', 'USD', 'USD', 'EUR', 'SAR'], npo), 'ARIBA_REQ_ID': np.where(rng.random(npo) < 0.7, ['PR' + str(900000 + i) for i in range(npo)], ''),
                   'STATUS': rng.choice(['CLOSED', 'CLOSED', 'CLOSED', 'OPEN', 'GR_POSTED'], npo)}).sort_values('BEDAT').reset_index(drop=True)
PO['NETWR'] = np.where(PO.WAERS == 'EUR', (PO.NETWR * 0.926).round(2), np.where(PO.WAERS == 'SAR', (PO.NETWR * SAR_PER_USD).round(2), PO.NETWR))
write(add_audit(PO, 'SAP', pd.to_datetime(PO.BEDAT).dt.to_period('M').astype(str)), BRONZE, 'sap_purchase_orders')
fx = PO.WAERS.map({'USD': 1.0, 'EUR': 1 / 0.926, 'SAR': 1 / SAR_PER_USD})
FPO = pd.DataFrame({'purchase_order_key': range(1, npo + 1), 'po_number': PO.EBELN, 'po_line': PO.EBELP, 'date_key': dkey(pd.to_datetime(PO.BEDAT)), 'entity_key': PO.KOSTL.map(CC_ENT).map(ENT_KEY),
                    'cost_center_key': PO.KOSTL.map(CC_KEY), 'gl_account_key': PO.SAKTO.map(GL_KEY), 'vendor_key': PO.LIFNR.map(lambda v: VKEY[DUP_MAP.get(v, v)]), 'source_vendor_id': PO.LIFNR, 'category': PO.MATKL,
                    'document_currency': PO.WAERS, 'amount_doc_currency': PO.NETWR, 'amount_usd': (PO.NETWR * fx).round(2), 'has_ariba_requisition': PO.ARIBA_REQ_ID != '', 'status': PO.STATUS, 'src_batch_id': 'SAP_' + pd.to_datetime(PO.BEDAT).dt.strftime('%Y%m') + '_001'})
write(FPO, GOLD, 'FACT_PURCHASE_ORDER')
req = PO[PO.ARIBA_REQ_ID != ''].sample(900, random_state=SEED)
ariba_req = pd.DataFrame({'REQUISITION_ID': req.ARIBA_REQ_ID, 'REQ_DATE': (pd.to_datetime(req.BEDAT) - pd.to_timedelta(rng.integers(2, 20, len(req)), unit='D')).dt.date, 'REQUESTER': rng.choice(PEOPLE[PEOPLE.grade >= 'G3'].employee_id.values, len(req)),
                          'SUPPLIER_ID': 'ARB-' + req.LIFNR.str[1:], 'COMMODITY': req.MATKL, 'COST_CENTER': req.KOSTL, 'AMOUNT': req.NETWR, 'CURRENCY': req.WAERS, 'APPROVAL_STATUS': 'Approved', 'ERP_PO_NUMBER': req.EBELN,
                          'CONTRACT_ID': np.where(rng.random(len(req)) < 0.5, ['CW' + str(300000 + i) for i in range(len(req))], ''), 'CYCLE_TIME_DAYS': rng.integers(1, 15, len(req))}).sort_values('REQ_DATE').reset_index(drop=True)
write(add_audit(ariba_req, 'ARIBA', pd.to_datetime(ariba_req.REQ_DATE).dt.to_period('M').astype(str)), BRONZE, 'ariba_requisitions')

# --------------------------------------------------------------------------- finance (monthly x cost centre x GL)
fin = []  # (period, cc, gl, airline, actual, budget_hint)
def post(period, cc, gl, amount, airline='', budget=None):
    fin.append(dict(period=period, cost_center_code=cc, gl_account=gl, airline_code=airline, amount_usd=round(float(amount), 2), budget_usd=None if budget is None else round(float(budget), 2)))

cat_m = FCU.assign(period=FCU.flight_date.dt.to_period('M').astype(str)).groupby(['period', 'airline_code', 'service_entity_code'], as_index=False).agg(rev=('revenue_usd', 'sum'), food=('food_cost_usd', 'sum'))
gh_m = adf.assign(period=adf.flight_date.dt.to_period('M').astype(str)).groupby(['period', 'airline_code', 'service_entity_code', 'station_code'], as_index=False).agg(rev=('handling_revenue_usd', 'sum'))
lab_m = LAB.groupby(['period', 'cost_center_code', 'deployed_cost_center_code', 'employment_type'], as_index=False).agg(reg=('regular_cost_usd', 'sum'), ot=('overtime_cost_usd', 'sum'), ben=('benefits_cost_usd', 'sum'))
OPEX_PROFILE = {  # cc: [(gl, base monthly USD, variable_with_season)]
    '1109': [('520100', 118000, True), ('520400', 16000, False), ('530400', 6000, True)], '1401': [('520200', 62000, True), ('520300', 31000, False), ('530400', 9000, False), ('530500', 2500, False)],
    '1402': [('600100', 185000, False), ('520400', 9000, False)], '1403': [('540100', 36000, False), ('530100', 22000, True)], '1509': [('530200', 0, False), ('530100', 38000, True), ('600200', 165000, False), ('550100', 12000, False)],
    '1201': [('530100', 46000, True), ('530400', 11000, True), ('600200', 42000, False)], '1202': [('530100', 21000, True), ('530400', 7000, True)], '1203': [('530100', 9000, True), ('530400', 3000, True)],
    '1204': [('500200', 0, True), ('520100', 24000, True), ('520400', 4000, False)], '1206': [('500300', 0, True)], '1207': [('530100', 14000, True), ('530400', 8000, True)], '1210': [('530600', 6000, False), ('530400', 2500, False)],
    '1303': [('530100', 26000, True), ('600200', 31000, False), ('530400', 4000, True)], '1301': [('530400', 3000, True), ('550100', 2500, False)], '1302': [('530400', 3000, True), ('550100', 2500, False)],
    '1502': [('530600', 16000, False), ('530700', 58000, False), ('700100', 29000, False), ('700200', 0, False)], '1503': [('510600', 19000, False), ('530800', 3000, False)], '1504': [('530300', 72000, False), ('600300', 15000, False)],
    '1505': [('550100', 4000, False)], '1506': [('530500', 3000, False), ('530600', 5000, False)], '1507': [('530900', 12000, False), ('530800', 9000, False)], '1508': [('530600', 21000, False)], '1501': [('530800', 8000, False), ('550100', 6000, False)],
    '1110': [('500100', 0, True), ('530100', 12000, True), ('530400', 9000, True)], '1111': [('530400', 4000, True)], '1103': [('530500', 4000, False), ('530400', 5000, False)], '1104': [('530400', 4000, True), ('530500', 2500, False)],
    '1101': [('530500', 5000, False), ('530400', 6000, True)], '1102': [('530500', 3000, False), ('530400', 4000, True)], '1106': [('530400', 7000, True), ('530500', 1500, False)], '1108': [('530400', 2000, True)],
    '2101': [('530600', 9000, False), ('530400', 4000, False), ('530200', 11000, False)], '2102': [('530800', 5000, False)], '2104': [('550100', 3000, False)],
    '3105': [('530600', 13000, False), ('530800', 6000, False)], '3106': [('530200', 62000, False), ('550100', 36000, False), ('520100', 9000, True)], '3107': [('530300', 4000, False), ('550100', 3000, False)],
    '4101': [('520100', 14000, True), ('530400', 4000, True), ('530500', 1500, False)], '4102': [('500100', 0, True), ('530100', 7000, True)], '4103': [('520100', 9000, True), ('530400', 3000, True)],
    '4104': [('530200', 24000, False), ('530600', 6000, False), ('800100', 9500, False), ('600100', 18000, False), ('530700', 7000, False)], '4105': [('520200', 9000, True), ('520300', 4000, False)],
}
for p in PERIODS:
    ps = pd.Period(p, 'M'); yr_g = 1.0 if ps.year == 2025 else 1.035; seas = float(season([ps.start_time])[0]); mi_ = (ps.year - 2025) * 12 + ps.month - 1
    # revenue from operations
    for _, r in cat_m[cat_m.period == p].iterrows():
        cc = '1209' if r.service_entity_code == 'ASC' else '4102'
        post(p, cc, '400210' if r.airline_code == 'CHR' else '400200', -r.rev, r.airline_code)
    for _, r in gh_m[gh_m.period == p].iterrows():
        cc = '1101' if r.service_entity_code == 'ASC' else ('4101' if r.station_code == 'DMM' else '4103')
        post(p, cc, '400100', -r.rev, r.airline_code)
    post(p, '1301', '400300', -330000 * yr_g * seas * rng.normal(1, 0.05)); post(p, '1302', '400300', -290000 * yr_g * seas * rng.normal(1, 0.05)); post(p, '1304', '400300', -28000 * yr_g * rng.normal(1, 0.08))
    post(p, '1110', '400700', -155000 * yr_g * seas * rng.normal(1, 0.04)); post(p, '1111', '400700', -42000 * yr_g * seas * rng.normal(1, 0.06))
    post(p, '2101', '400600', -92000 * yr_g * rng.normal(1, 0.1)); post(p, '2102', '400600', -58000 * yr_g * rng.normal(1, 0.15)); post(p, '2103', '400600', -34000 * yr_g * rng.normal(1, 0.1))
    post(p, '1401', '400400', -36000 * yr_g * rng.normal(1, 0.1)); post(p, '1501', '400900', -24000 * rng.normal(1, 0.2))
    # food cost split across kitchens; packaging & bonded derived
    food_asc = cat_m[(cat_m.period == p) & (cat_m.service_entity_code == 'ASC')].food.sum(); food_dmm = cat_m[(cat_m.period == p) & (cat_m.service_entity_code == 'ASCSA')].food.sum()
    for cc, sh in [('1201', 0.55), ('1202', 0.30), ('1203', 0.15)]:
        post(p, cc, '500100', food_asc * sh)
    post(p, '4102', '500100', food_dmm); post(p, '1204', '500200', food_asc * 0.14 * rng.normal(1, 0.04)); post(p, '1206', '500300', food_asc * 0.07 * rng.normal(1, 0.05)); post(p, '1110', '500100', 38000 * seas * rng.normal(1, 0.05))
    # labour
    for _, r in lab_m[lab_m.period == p].iterrows():
        if r.employment_type == 'Permanent':
            post(p, r.cost_center_code, '510100', r.reg); post(p, r.cost_center_code, '510200', r.ot); post(p, r.cost_center_code, '510500', r.ben)
        else:
            post(p, r.cost_center_code, '510300', r.reg); post(p, r.cost_center_code, '510400', r.ot)
            ic = (r.reg + r.ot) * 1.18
            post(p, r.deployed_cost_center_code, '510700', ic); post(p, r.cost_center_code, '400500', -ic)
    # other opex
    for cc, items in OPEX_PROFILE.items():
        for gl, base, var in items:
            if base == 0:
                continue
            amt = base * 1.25 * yr_g * (seas if var else 1.0) * (1 + 0.0015 * mi_) * rng.normal(1, 0.06)
            if gl == '700200':
                amt = rng.normal(0, 6000)
            post(p, cc, gl, amt)
    # BAC concession fee = 6% of ASC external revenue this month
    ext_rev = -sum(f['amount_usd'] for f in fin if f['period'] == p and f['gl_account'].startswith('400') and f['gl_account'] not in ('400500',) and CC_ENT[f['cost_center_code']] == 'ASC')
    post(p, '1509', '530200', ext_rev * 0.08 + 120000)
FIN = pd.DataFrame(fin)
FIN = FIN.groupby(['period', 'cost_center_code', 'gl_account', 'airline_code'], as_index=False).agg(amount_usd=('amount_usd', 'sum'))
FIN['amount_usd'] = FIN.amount_usd.round(2)
# budget: 2025 = actual with planning noise; 2026 = prior-year same month x 1.045 (so Q3 FY26 overruns are real)
prior = FIN[FIN.period < '2026'].copy(); prior['period'] = prior.period.str.replace('2025', '2026'); prior = prior.rename(columns={'amount_usd': 'prior'})
FIN = FIN.merge(prior, on=['period', 'cost_center_code', 'gl_account', 'airline_code'], how='left')
noise = rng.normal(1, 0.035, len(FIN))
FIN['budget_usd'] = np.where(FIN.period < '2026', FIN.amount_usd * noise, np.where(FIN.prior.notna(), FIN.prior * 1.045, FIN.amount_usd * 0.95)).round(2)
FIN = FIN.drop(columns=['prior'])
FIN['posting_count'] = rng.integers(2, 60, len(FIN))
FIN['entity_code'] = FIN.cost_center_code.map(CC_ENT)
pend = pd.PeriodIndex(FIN.period, freq='M').to_timestamp(how='end').normalize()
FFP = pd.DataFrame({'finance_posting_key': range(1, len(FIN) + 1), 'fiscal_period': FIN.period, 'fiscal_year': FIN.period.str[:4].astype(int), 'date_key': pend.strftime('%Y%m%d').astype(int), 'entity_key': FIN.entity_code.map(ENT_KEY),
                    'cost_center_key': FIN.cost_center_code.map(CC_KEY), 'gl_account_key': FIN.gl_account.map(GL_KEY), 'airline_key': FIN.airline_code.map(AL_KEY).astype('Int64'), 'amount_usd': FIN.amount_usd, 'budget_usd': FIN.budget_usd,
                    'variance_usd': (FIN.amount_usd - FIN.budget_usd).round(2), 'posting_count': FIN.posting_count, 'src_batch_id': 'SAP_' + FIN.period.str.replace('-', '') + '_001'})
write(FFP, GOLD, 'FACT_FINANCE_POSTING')
sap_gl = pd.DataFrame({'BUKRS': FIN.entity_code.map(ENT_SAP), 'GJAHR': FIN.period.str[:4], 'MONAT': FIN.period.str[5:].astype(int), 'KOSTL': FIN.cost_center_code, 'HKONT': FIN.gl_account,
                       'PRCTR': np.where(FIN.airline_code != '', 'PC_' + FIN.airline_code, 'PC_GEN'), 'WAERS': np.where(FIN.entity_code == 'ASCSA', 'SAR', 'USD'),
                       'WRBTR': np.where(FIN.entity_code == 'ASCSA', (FIN.amount_usd * SAR_PER_USD).round(2), FIN.amount_usd), 'HWAER': 'USD', 'DMBTR': FIN.amount_usd, 'POSTING_COUNT': FIN.posting_count, 'BUDAT': pend.strftime('%Y-%m-%d')})
write(add_audit(sap_gl, 'SAP', FIN.period), BRONZE, 'sap_gl_actuals_monthly')
sap_bud = pd.DataFrame({'BUKRS': FIN.entity_code.map(ENT_SAP), 'GJAHR': FIN.period.str[:4], 'MONAT': FIN.period.str[5:].astype(int), 'KOSTL': FIN.cost_center_code, 'HKONT': FIN.gl_account, 'PRCTR': np.where(FIN.airline_code != '', 'PC_' + FIN.airline_code, 'PC_GEN'),
                        'VERSN': '0', 'PLAN_AMOUNT_USD': FIN.budget_usd})
write(add_audit(sap_bud, 'SAP', FIN.period), BRONZE, 'sap_co_budget_monthly')

# --------------------------------------------------------------------------- AGG_MONTHLY_AIRLINE_PNL
cm = FCU.assign(period=FCU.flight_date.dt.to_period('M').astype(str)).groupby(['period', 'airline_code'], as_index=False).agg(meals=('meals_uplifted', 'sum'), wasted=('meals_wasted', 'sum'), cat_rev=('revenue_usd', 'sum'), cat_cost=('total_cost_usd', 'sum'),
                                                                                                                             food=('food_cost_usd', 'sum'), labour=('labour_cost_usd', 'sum'), late=('late_downlift_confirmations', 'sum'), deliv=('deliveries_total', 'sum'), ontime=('deliveries_on_time', 'sum'))
gm = adf.assign(period=adf.flight_date.dt.to_period('M').astype(str)).groupby(['period', 'airline_code'], as_index=False).agg(flights=('flights_handled', 'sum'), gh_rev=('handling_revenue_usd', 'sum'))
PNL = gm.merge(cm, on=['period', 'airline_code'], how='left').fillna(0)
PNL['gh_cost'] = (PNL.gh_rev * 0.82 * rng.normal(1, 0.02, len(PNL))).round(2)
AGG_PNL = pd.DataFrame({'fiscal_period': PNL.period, 'airline_key': PNL.airline_code.map(AL_KEY), 'flights_handled': PNL.flights, 'meals_uplifted': PNL.meals.astype(int), 'meals_wasted': PNL.wasted.astype(int), 'catering_revenue_usd': PNL.cat_rev.round(2),
                        'catering_cost_usd': PNL.cat_cost.round(2), 'catering_food_cost_usd': PNL.food.round(2), 'catering_labour_cost_usd': PNL.labour.round(2), 'handling_revenue_usd': PNL.gh_rev.round(2), 'handling_cost_usd': PNL.gh_cost,
                        'late_downlift_confirmations': PNL.late.astype(int), 'deliveries_total': PNL.deliv.astype(int), 'deliveries_on_time': PNL.ontime.astype(int)})
AGG_PNL['total_revenue_usd'] = (AGG_PNL.catering_revenue_usd + AGG_PNL.handling_revenue_usd).round(2)
AGG_PNL['contribution_margin_usd'] = (AGG_PNL.total_revenue_usd - AGG_PNL.catering_cost_usd - AGG_PNL.handling_cost_usd).round(2)
AGG_PNL['cost_per_meal_usd'] = np.where(AGG_PNL.meals_uplifted > 0, (AGG_PNL.catering_cost_usd / AGG_PNL.meals_uplifted.replace(0, np.nan)).round(3), np.nan)
AGG_PNL['cost_per_flight_usd'] = (AGG_PNL.handling_cost_usd / AGG_PNL.flights_handled).round(2)
write(AGG_PNL, GOLD, 'AGG_MONTHLY_AIRLINE_PNL')

# --------------------------------------------------------------------------- remaining dimensions
DIM_DATE = pd.DataFrame({'date_key': DATES.strftime('%Y%m%d').astype(int), 'calendar_date': DATES.date, 'year': DATES.year, 'quarter': DATES.quarter, 'month': DATES.month, 'month_name': DATES.strftime('%b'),
                         'fiscal_year': DATES.year, 'fiscal_quarter': ['FY' + str(y)[2:] + ' Q' + str(q) for y, q in zip(DATES.year, DATES.quarter)], 'fiscal_period': DATES.strftime('%Y-%m'), 'day_of_week': DATES.dayofweek + 1,
                         'day_name': DATES.strftime('%a'), 'is_weekend': DATES.dayofweek >= 4, 'week_of_year': DATES.isocalendar().week.values,
                         'is_ramadan': ((DATES >= '2025-03-01') & (DATES <= '2025-03-30')) | ((DATES >= '2026-02-18') & (DATES <= '2026-03-19')), 'is_peak_season': DATES.month.isin([6, 7, 8, 12])})
write(DIM_DATE, GOLD, 'DIM_DATE'); write(ENTITIES, GOLD, 'DIM_ENTITY'); write(AIRLINES, GOLD, 'DIM_AIRLINE'); write(STATIONS, GOLD, 'DIM_STATION')
DIM_FLIGHT = SCHED.drop(columns=['operate_prob']).copy()
DIM_FLIGHT['airline_key'] = DIM_FLIGHT.airline_code.map(AL_KEY); DIM_FLIGHT['station_key'] = DIM_FLIGHT.station_code.map(ST_KEY); DIM_FLIGHT['entity_key'] = DIM_FLIGHT.service_entity_code.map(ENT_KEY)
write(DIM_FLIGHT, GOLD, 'DIM_FLIGHT'); write(DIM_CC, GOLD, 'DIM_COST_CENTER'); write(DIM_GL, GOLD, 'DIM_GL_ACCOUNT'); write(DIM_MEAL, GOLD, 'DIM_MEAL')

# --------------------------------------------------------------------------- headline numbers for the README / recon
ebitda = FFP.merge(DIM_GL[['gl_account_key', 'is_ebitda', 'is_intercompany', 'account_class']], on='gl_account_key')
ext = ebitda[~ebitda.is_intercompany]
summary = {}
for fy in (2025, 2026):
    s = ext[ext.fiscal_year == fy]
    rev = -s[s.account_class == 'Revenue'].amount_usd.sum(); eb = -s[s.is_ebitda].amount_usd.sum()
    summary[f'FY{fy}'] = dict(revenue_usd=round(rev, 2), ebitda_usd=round(eb, 2), ebitda_margin_pct=round(100 * eb / rev, 2), months=int(s.fiscal_period.nunique()))
q = cm[cm.period.isin(['2026-07', '2026-08', '2026-09'])].groupby('airline_code').agg(meals=('meals', 'sum'), cost=('cat_cost', 'sum'))
q2 = cm[cm.period.isin(['2026-04', '2026-05', '2026-06'])].groupby('airline_code').agg(meals=('meals', 'sum'), cost=('cat_cost', 'sum'))
cpm = pd.DataFrame({'q3_fy26': (q.cost / q.meals).round(3), 'q2_fy26': (q2.cost / q2.meals).round(3)}); cpm['change_pct'] = (100 * (cpm.q3_fy26 / cpm.q2_fy26 - 1)).round(1)
summary['cost_per_meal_q3_vs_q2_fy26'] = cpm.to_dict('index')
gfe = FCU[(FCU.airline_code == 'GC') & (FCU.route_group == 'Europe')].assign(period=FCU.flight_date.dt.to_period('M').astype(str)).groupby('period').agg(w=('meals_wasted', 'sum'), u=('meals_uplifted', 'sum'))
summary['gf_europe_wastage_pct'] = {k: round(100 * v, 2) for k, v in (gfe.w / gfe.u).tail(4).items()}
t114 = AGG_ASSET[AGG_ASSET.asset_id == 'T-114'].set_index('fiscal_period')[['failures', 'hydraulic_faults', 'downtime_hours', 'downtime_cost_usd']].tail(8)
summary['t114_recent'] = t114.to_dict('index')
summary['ascwf_contractor_ot_hours'] = {'2026-08': int(aug), '2026-09': int(CONT.loc[CONT.period == '2026-09', 'overtime_hours'].sum()), 'delta': 318}
summary['vendor_mdm'] = {'raw_vendor_records': int(len(VEND_RAW)), 'golden_records': int(len(VEND)), 'duplicates': int(len(dups))}
summary['bronze_cms_live_rows'] = int(len(live_b)); summary['bronze_cms_live_duplicates'] = 26
summary['row_counts'] = {'flight_days': int(len(FD)), 'fact_catering_uplift': int(len(FCU_G)), 'fact_finance_posting': int(len(FFP)), 'fact_work_order': int(len(FWO)), 'fact_labour_cost': int(len(FLC)), 'fact_airline_order': int(len(FAO)), 'employees': int(len(DIM_EMP))}
with open(os.path.join(BASE, 'data', 'control_totals.json'), 'w') as fh:
    json.dump(summary, fh, indent=2, default=str)
print(json.dumps(summary, indent=2, default=str))
