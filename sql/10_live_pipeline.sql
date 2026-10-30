-- =============================================================================
-- 10_live_pipeline.sql  |  Live SITA feed: a stream plus a three-step task graph
-- New rows in EDW_BRONZE.RAW.SITA_MESSAGES (batch_id 'SITA_LIVE', sent by a feed script during the demo)
-- flow on their own, within about a minute: Bronze -> Silver SITA_MOVEMENTS -> Gold LIVE_FLIGHT_BOARD,
-- and every run is logged. Snowsight shows the graph, run history and retries:
--   Catalog > EDW_BRONZE > LANDING > Tasks > T_SITA_SILVER > Graph / Run history.
-- The live rows are kept apart from the certified history (Sep-2026 story numbers do not change).
-- Run after 01-08b. Serverless tasks, so no warehouse stays running for them.
-- =============================================================================
USE ROLE ACCOUNTADMIN;
GRANT EXECUTE TASK ON ACCOUNT TO ROLE ROLE_ELT_ADMIN;
GRANT EXECUTE MANAGED TASK ON ACCOUNT TO ROLE ROLE_ELT_ADMIN;

USE ROLE ROLE_ELT_ADMIN;
USE WAREHOUSE WH_ELT;

-- ------------------------------------------------------------------ targets
-- Today's departures per station and airline, from live SITA MVT/CAT messages only.
CREATE OR REPLACE TABLE EDW_GOLD.AGG.LIVE_FLIGHT_BOARD (
  flight_date DATE, entity_key NUMBER(3), station_key NUMBER(3), airline_key NUMBER(4),
  station_code VARCHAR(3), airline_code VARCHAR(3),
  departures NUMBER(6), departures_on_time NUMBER(6), on_time_pct NUMBER(5,1), avg_delay_min NUMBER(6,1),
  catering_confirmations NUMBER(6), last_message_at TIMESTAMP_NTZ, refreshed_at TIMESTAMP_NTZ
) COMMENT = 'Live SITA board: departures and on-time % per station and airline, refreshed by task T_SITA_GOLD';
-- Same row security as AGG_DAILY_FLIGHTS: a station manager sees only their own station, an AM only their airlines.
ALTER TABLE EDW_GOLD.AGG.LIVE_FLIGHT_BOARD ADD ROW ACCESS POLICY EDW_GOLD.SECURITY.RAP_ENTITY_STATION_AIRLINE ON (entity_key, station_key, airline_key);

CREATE OR REPLACE TABLE EDW_GOLD.CONTROL.PIPELINE_RUN_LOG (
  run_at TIMESTAMP_NTZ, task_graph VARCHAR(40), live_messages NUMBER(8), board_rows NUMBER(6),
  unknown_flight_messages NUMBER(6), last_message_at TIMESTAMP_NTZ, status VARCHAR(10)
) COMMENT = 'One row per run of the live SITA task graph; unknown_flight_messages > 0 marks the run WARN';

-- ------------------------------------------------------------------ stream
-- Append-only: SITA messages are never updated in place, only added.
CREATE OR REPLACE STREAM EDW_BRONZE.LANDING.SITA_MESSAGES_STREAM
  ON TABLE EDW_BRONZE.RAW.SITA_MESSAGES APPEND_ONLY = TRUE
  COMMENT = 'New SITA messages not yet moved to Silver';

-- ------------------------------------------------------------------ task graph
-- Tasks in one graph share an owner and a schema. Suspend before replacing so a rerun of this file is safe.
ALTER TASK IF EXISTS EDW_BRONZE.LANDING.T_SITA_SILVER SUSPEND;

-- 1. Root: triggered by the stream (no schedule), moves new messages to Silver with the 03 transform.
CREATE OR REPLACE TASK EDW_BRONZE.LANDING.T_SITA_SILVER
  USER_TASK_MANAGED_INITIAL_WAREHOUSE_SIZE = 'XSMALL'
  TARGET_COMPLETION_INTERVAL = '1 MINUTE'   -- required for a serverless triggered task
  TASK_AUTO_RETRY_ATTEMPTS = 2
  COMMENT = 'Live SITA step 1: Bronze stream -> Silver SITA_MOVEMENTS'
  WHEN SYSTEM$STREAM_HAS_DATA('EDW_BRONZE.LANDING.SITA_MESSAGES_STREAM')
AS
MERGE INTO EDW_SILVER.CONFORMED.SITA_MOVEMENTS t
USING (
  SELECT MSG_ID, MSG_TYPE, FLT_NO AS flight_number, FLT_DATE AS flight_date, AC_REG, ORIGIN, DEST, STATION AS station_code,
         TRY_TO_TIMESTAMP_NTZ(STD, 'YYYY-MM-DD HH24:MI') AS std_ts, TRY_TO_TIMESTAMP_NTZ(ATD, 'YYYY-MM-DD HH24:MI') AS atd_ts,
         DELAY_MIN, DELAY_CODE, IFF(DELAY_MIN <= 15, 1, 0) AS on_time_flag, BATCH_ID AS src_batch_id
  FROM EDW_BRONZE.LANDING.SITA_MESSAGES_STREAM
  QUALIFY ROW_NUMBER() OVER (PARTITION BY MSG_ID ORDER BY EXTRACTED_AT DESC) = 1
) s ON t.MSG_ID = s.MSG_ID
WHEN NOT MATCHED THEN INSERT (MSG_ID, MSG_TYPE, FLIGHT_NUMBER, FLIGHT_DATE, AC_REG, ORIGIN, DEST, STATION_CODE, STD_TS, ATD_TS, DELAY_MIN, DELAY_CODE, ON_TIME_FLAG, SRC_BATCH_ID)
  VALUES (s.MSG_ID, s.MSG_TYPE, s.flight_number, s.flight_date, s.AC_REG, s.ORIGIN, s.DEST, s.station_code, s.std_ts, s.atd_ts, s.DELAY_MIN, s.DELAY_CODE, s.on_time_flag, s.src_batch_id);

-- 2. Rebuild the live board from every live message in Silver (small, so a full rebuild is simplest).
CREATE OR REPLACE TASK EDW_BRONZE.LANDING.T_SITA_GOLD
  USER_TASK_MANAGED_INITIAL_WAREHOUSE_SIZE = 'XSMALL'
  COMMENT = 'Live SITA step 2: Silver -> Gold LIVE_FLIGHT_BOARD'
  AFTER EDW_BRONZE.LANDING.T_SITA_SILVER
AS
INSERT OVERWRITE INTO EDW_GOLD.AGG.LIVE_FLIGHT_BOARD
SELECT s.flight_date, f.entity_key, f.station_key, f.airline_key, f.station_code, f.airline_code,
       COUNT_IF(s.msg_type = 'MVT') AS departures,
       SUM(IFF(s.msg_type = 'MVT', s.on_time_flag, 0)) AS departures_on_time,
       ROUND(100 * SUM(IFF(s.msg_type = 'MVT', s.on_time_flag, 0)) / NULLIF(COUNT_IF(s.msg_type = 'MVT'), 0), 1) AS on_time_pct,
       ROUND(AVG(IFF(s.msg_type = 'MVT', s.delay_min, NULL)), 1) AS avg_delay_min,
       COUNT_IF(s.msg_type = 'CAT') AS catering_confirmations,
       MAX(COALESCE(s.atd_ts, s.std_ts)) AS last_message_at,
       CURRENT_TIMESTAMP()::TIMESTAMP_NTZ AS refreshed_at
FROM EDW_SILVER.CONFORMED.SITA_MOVEMENTS s
JOIN EDW_GOLD.STAR.DIM_FLIGHT f ON f.flight_number = s.flight_number AND f.station_code = s.station_code
WHERE s.src_batch_id = 'SITA_LIVE'
GROUP BY 1, 2, 3, 4, 5, 6;

-- 3. Log the run and check that every live message matched a scheduled flight (else WARN).
CREATE OR REPLACE TASK EDW_BRONZE.LANDING.T_SITA_LOG
  USER_TASK_MANAGED_INITIAL_WAREHOUSE_SIZE = 'XSMALL'
  COMMENT = 'Live SITA step 3: run log and unknown-flight check'
  AFTER EDW_BRONZE.LANDING.T_SITA_GOLD
AS
INSERT INTO EDW_GOLD.CONTROL.PIPELINE_RUN_LOG
SELECT CURRENT_TIMESTAMP()::TIMESTAMP_NTZ, 'SITA_LIVE',
       (SELECT COUNT(*) FROM EDW_SILVER.CONFORMED.SITA_MOVEMENTS WHERE src_batch_id = 'SITA_LIVE'),
       (SELECT COUNT(*) FROM EDW_GOLD.AGG.LIVE_FLIGHT_BOARD),
       u.n, (SELECT MAX(last_message_at) FROM EDW_GOLD.AGG.LIVE_FLIGHT_BOARD), IFF(u.n > 0, 'WARN', 'OK')
FROM (SELECT COUNT(*) AS n FROM EDW_SILVER.CONFORMED.SITA_MOVEMENTS s
      WHERE s.src_batch_id = 'SITA_LIVE'
        AND NOT EXISTS (SELECT 1 FROM EDW_GOLD.STAR.DIM_FLIGHT f WHERE f.flight_number = s.flight_number AND f.station_code = s.station_code)) u;

-- Resume children before the root (one call does all dependents).
SELECT SYSTEM$TASK_DEPENDENTS_ENABLE('EDW_BRONZE.LANDING.T_SITA_SILVER');

-- Watch it work (as ROLE_ELT_ADMIN or ACCOUNTADMIN):
-- SELECT * FROM EDW_GOLD.AGG.LIVE_FLIGHT_BOARD ORDER BY departures DESC;
-- SELECT * FROM EDW_GOLD.CONTROL.PIPELINE_RUN_LOG ORDER BY run_at DESC LIMIT 10;
-- SELECT name, state, scheduled_time, completed_time, error_message
--   FROM TABLE(EDW_BRONZE.INFORMATION_SCHEMA.TASK_HISTORY()) ORDER BY scheduled_time DESC LIMIT 20;
