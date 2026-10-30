-- =============================================================================
-- 11_wastage_alert.sql | Email alert when an airline-route's wastage crosses the 4% threshold
-- Flow: a Snowflake ALERT checks every 15 minutes whether the latest month has an airline-route above 4% that
-- has not been reported yet; if so it calls SP_WASTAGE_ALERT, which emails the new breaches and logs them, so
-- each airline-route is reported once per month. Run as ACCOUNTADMIN (integration, grants), then ROLE_ELT_ADMIN.
-- Test without sending anything: CALL EDW_GOLD.CONTROL.SP_WASTAGE_ALERT(FALSE);  (shows the email it would send)
-- The alert is created SUSPENDED. Start it with: ALTER ALERT EDW_GOLD.CONTROL.AL_WASTAGE_ABOVE_4 RESUME;
-- =============================================================================
USE ROLE ACCOUNTADMIN;

-- Snowflake only emails addresses that are verified on a Snowflake user.
CREATE NOTIFICATION INTEGRATION IF NOT EXISTS INT_EMAIL_ALERTS
  TYPE = EMAIL ENABLED = TRUE
  ALLOWED_RECIPIENTS = ('<ALERT_EMAIL>')
  COMMENT = 'Alert emails from the ASC demo (verified recipients only)';
GRANT USAGE ON INTEGRATION INT_EMAIL_ALERTS TO ROLE ROLE_ELT_ADMIN;
GRANT EXECUTE ALERT ON ACCOUNT TO ROLE ROLE_ELT_ADMIN;

USE ROLE ROLE_ELT_ADMIN;
USE WAREHOUSE WH_ELT;

CREATE TABLE IF NOT EXISTS EDW_GOLD.CONTROL.ALERT_LOG (
  alert_name VARCHAR(60), fiscal_period VARCHAR(7), airline_route VARCHAR(120),
  wastage_pct NUMBER(8,2), previous_pct NUMBER(8,2), alerted_at TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP())
  COMMENT = 'One row per alert sent: which airline-route, which month, so it is reported once';

-- Airline-routes above 4% in the latest month, with the month before for context.
CREATE OR REPLACE VIEW EDW_GOLD.CONTROL.V_WASTAGE_BREACHES AS
WITH m AS (
  SELECT airline_name || ' · ' || route_group AS airline_route, fiscal_period,
         100 * SUM(meals_wasted) / NULLIF(SUM(meals_uplifted), 0) AS wastage_pct
  FROM EDW_GOLD.SEMANTIC.V_CATERING_UPLIFT GROUP BY 1, 2),
l AS (
  SELECT airline_route, fiscal_period, wastage_pct,
         LAG(wastage_pct) OVER (PARTITION BY airline_route ORDER BY fiscal_period) AS previous_pct FROM m)
SELECT airline_route, fiscal_period, ROUND(wastage_pct, 2) AS wastage_pct, ROUND(previous_pct, 2) AS previous_pct
FROM l WHERE fiscal_period = (SELECT MAX(fiscal_period) FROM m) AND wastage_pct > 4;

CREATE OR REPLACE PROCEDURE EDW_GOLD.CONTROL.SP_WASTAGE_ALERT(SEND BOOLEAN DEFAULT TRUE)
RETURNS STRING LANGUAGE SQL
AS
$$
DECLARE
  n INTEGER; period STRING; body STRING; subject STRING;
BEGIN
  CREATE OR REPLACE TEMPORARY TABLE new_breaches AS
    SELECT b.* FROM EDW_GOLD.CONTROL.V_WASTAGE_BREACHES b
    WHERE NOT EXISTS (SELECT 1 FROM EDW_GOLD.CONTROL.ALERT_LOG l
                      WHERE l.alert_name = 'AL_WASTAGE_ABOVE_4' AND l.fiscal_period = b.fiscal_period AND l.airline_route = b.airline_route);
  SELECT COUNT(*), MAX(fiscal_period),
         LISTAGG(airline_route || ': ' || wastage_pct || '%' || IFF(previous_pct IS NULL, '', ' (previous month ' || previous_pct || '%)'), '
')
           WITHIN GROUP (ORDER BY wastage_pct DESC)
    INTO :n, :period, :body FROM new_breaches;
  IF (n = 0) THEN
    RETURN 'No new airline-route above 4%.';
  END IF;
  subject := 'ASC alert: wastage above 4% in ' || period || ' (' || n || ' airline-route' || IFF(n = 1, '', 's') || ')';
  body := 'Meal wastage is above the 4% threshold in ' || period || ':' || CHR(10) || CHR(10) || body || CHR(10) || CHR(10)
          || 'Details: Group executive cockpit, Catering: Wastage.';
  IF (NOT SEND) THEN
    RETURN 'DRY RUN, nothing sent. Subject: ' || subject || CHR(10) || body;
  END IF;
  CALL SYSTEM$SEND_EMAIL('INT_EMAIL_ALERTS', '<ALERT_EMAIL>', :subject, :body);   -- first, so a failed send is retried next run
  INSERT INTO EDW_GOLD.CONTROL.ALERT_LOG (alert_name, fiscal_period, airline_route, wastage_pct, previous_pct)
    SELECT 'AL_WASTAGE_ABOVE_4', fiscal_period, airline_route, wastage_pct, previous_pct FROM new_breaches;
  RETURN 'Sent: ' || subject;
END;
$$;

CREATE OR REPLACE ALERT EDW_GOLD.CONTROL.AL_WASTAGE_ABOVE_4
  WAREHOUSE = WH_ELT
  SCHEDULE = '15 MINUTE'
  IF (EXISTS (SELECT 1 FROM EDW_GOLD.CONTROL.V_WASTAGE_BREACHES b
              WHERE NOT EXISTS (SELECT 1 FROM EDW_GOLD.CONTROL.ALERT_LOG l
                                WHERE l.alert_name = 'AL_WASTAGE_ABOVE_4' AND l.fiscal_period = b.fiscal_period AND l.airline_route = b.airline_route)))
  THEN CALL EDW_GOLD.CONTROL.SP_WASTAGE_ALERT(TRUE);

-- Dry run: what the first email would say, without sending or logging anything.
CALL EDW_GOLD.CONTROL.SP_WASTAGE_ALERT(FALSE);
SHOW ALERTS LIKE 'AL_WASTAGE_ABOVE_4' IN SCHEMA EDW_GOLD.CONTROL;
