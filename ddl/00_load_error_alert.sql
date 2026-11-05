-- ============================================================
-- SOMATUS DEMO · 00 LOAD ERROR ALERT
-- When a client file loads with rejected rows, email the ops team:
--   summary + reason breakdown + first 20 rejected rows in the body,
--   and a 7-day download link to a CSV of every rejected row.
-- Email attachments are not supported by SYSTEM$SEND_EMAIL, so the CSV is a link.
-- ============================================================
USE ROLE ACCOUNTADMIN;

-- Which bad files have already been reported (so each file is emailed once)
CREATE TABLE IF NOT EXISTS SOMATUS_DEMO.OPS.LOAD_ERROR_LOG (
  FILE_NAME STRING, TABLE_NAME STRING, ROWS_IN_FILE NUMBER, ROWS_LOADED NUMBER,
  ROWS_REJECTED NUMBER, CSV_URL STRING, REPORTED_AT TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP());

-- Where the rejected-row CSVs are written (SSE so the pre-signed link opens in a browser)
CREATE STAGE IF NOT EXISTS SOMATUS_DEMO.OPS.LOAD_ERROR_EXPORTS
  ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE')
  COMMENT = 'Rejected-row CSVs linked from load error emails';

CREATE OR REPLACE PROCEDURE SOMATUS_DEMO.OPS.SP_NOTIFY_LOAD_ERRORS(LOOKBACK_HOURS NUMBER DEFAULT 1)
RETURNS VARCHAR LANGUAGE SQL AS
$$
DECLARE
  sent INTEGER DEFAULT 0;
  start_ts TIMESTAMP_LTZ DEFAULT DATEADD('hour', -1 * LOOKBACK_HOURS, CURRENT_TIMESTAMP());
  tbl STRING; pipe STRING; fname STRING; loc STRING; stat STRING;
  parsed NUMBER; loaded NUMBER; rejected NUMBER; ts TIMESTAMP_LTZ;
  csv_path STRING; url STRING; reasons STRING; rows_html STRING; body STRING; subj STRING;
  rs RESULTSET;
BEGIN
  -- Files loaded with errors in the lookback window that have not been reported yet
  rs := (
    SELECT h.SRC_TABLE, h.PIPE_NAME, h.FILE_NAME, h.STAGE_LOCATION, h.STATUS,
           h.ROW_PARSED, h.ROW_COUNT, h.ERROR_COUNT, h.LAST_LOAD_TIME
    FROM (
      SELECT 'MEMBERS_RAW' AS SRC_TABLE, * FROM TABLE(SOMATUS_DEMO.INFORMATION_SCHEMA.COPY_HISTORY(
             TABLE_NAME => 'SOMATUS_DEMO.BRONZE.MEMBERS_RAW', START_TIME => :start_ts))
      UNION ALL
      SELECT 'CLAIMS_RAW', * FROM TABLE(SOMATUS_DEMO.INFORMATION_SCHEMA.COPY_HISTORY(
             TABLE_NAME => 'SOMATUS_DEMO.BRONZE.CLAIMS_RAW', START_TIME => :start_ts))
    ) h
    WHERE h.ERROR_COUNT > 0
      AND NOT EXISTS (SELECT 1 FROM SOMATUS_DEMO.OPS.LOAD_ERROR_LOG l WHERE l.FILE_NAME = h.FILE_NAME));

  FOR r IN rs DO
    tbl := r.SRC_TABLE; pipe := 'SOMATUS_DEMO.BRONZE.' || r.PIPE_NAME; fname := r.FILE_NAME;
    loc := r.STAGE_LOCATION; stat := r.STATUS; parsed := r.ROW_PARSED; loaded := r.ROW_COUNT;
    rejected := r.ERROR_COUNT; ts := r.LAST_LOAD_TIME;

    -- 1. Rejected rows for this file
    CREATE OR REPLACE TEMPORARY TABLE SOMATUS_DEMO.OPS.TMP_REJECTED AS
      SELECT LINE, REGEXP_SUBSTR(COLUMN_NAME, '\\["([A-Z_0-9]+)"', 1, 1, 'e') AS COLUMN_NAME,
             ERROR, REJECTED_RECORD
      FROM TABLE(SOMATUS_DEMO.INFORMATION_SCHEMA.VALIDATE_PIPE_LOAD(
             PIPE_NAME => :pipe, START_TIME => :start_ts))
      WHERE ENDSWITH(FILE, :fname);

    -- 2. Full CSV on a stage, plus a 7-day download link
    csv_path := 'rejected_' || REPLACE(fname, '.', '_') || '_' || TO_CHAR(CURRENT_TIMESTAMP(), 'YYYYMMDDHH24MISS') || '.csv';
    EXECUTE IMMEDIATE 'COPY INTO @SOMATUS_DEMO.OPS.LOAD_ERROR_EXPORTS/' || csv_path ||
      ' FROM (SELECT * FROM SOMATUS_DEMO.OPS.TMP_REJECTED ORDER BY LINE)' ||
      ' FILE_FORMAT = (TYPE = CSV COMPRESSION = NONE FIELD_OPTIONALLY_ENCLOSED_BY = ''"'')' ||
      ' HEADER = TRUE SINGLE = TRUE OVERWRITE = TRUE';
    LET url_rs RESULTSET := (EXECUTE IMMEDIATE
      'SELECT GET_PRESIGNED_URL(@SOMATUS_DEMO.OPS.LOAD_ERROR_EXPORTS, ''' || csv_path || ''', 604800) AS U');
    LET url_c CURSOR FOR url_rs;
    OPEN url_c; FETCH url_c INTO url; CLOSE url_c;

    -- 3. Reason summary and first 20 rows as HTML tables
    SELECT LISTAGG('<tr><td>' || ERROR || '</td><td>' || COALESCE(COLUMN_NAME, '') ||
                   '</td><td align="right">' || N || '</td></tr>', '') WITHIN GROUP (ORDER BY N DESC)
      INTO :reasons
      FROM (SELECT ERROR, COLUMN_NAME, COUNT(*) AS N FROM SOMATUS_DEMO.OPS.TMP_REJECTED GROUP BY 1, 2);
    SELECT LISTAGG('<tr><td align="right">' || LINE || '</td><td>' || COALESCE(COLUMN_NAME, '') || '</td><td>' || ERROR ||
                   '</td><td style="font-family:monospace">' ||
                   REPLACE(REPLACE(REPLACE(LEFT(REJECTED_RECORD, 100), '&', '&amp;'), '<', '&lt;'), '>', '&gt;') ||
                   IFF(LENGTH(REJECTED_RECORD) > 100, '...', '') || '</td></tr>', '') WITHIN GROUP (ORDER BY LINE)
      INTO :rows_html
      FROM (SELECT * FROM SOMATUS_DEMO.OPS.TMP_REJECTED ORDER BY LINE LIMIT 20);

    subj := 'Load issue: ' || fname || ' - ' || rejected || ' of ' || parsed || ' rows rejected';
    body := '<div style="font-family:Arial,sans-serif;font-size:14px;color:#222">' ||
      '<h2 style="color:#b45309;margin:0 0 8px">Load issue: file partially loaded</h2>' ||
      '<p><b>File:</b> ' || loc || fname ||
      '<br><b>Pipe / table:</b> ' || pipe || ' &rarr; BRONZE.' || tbl ||
      '<br><b>Loaded at:</b> ' || TO_CHAR(ts, 'YYYY-MM-DD HH24:MI:SS TZH:TZM') ||
      '<br><b>Status:</b> ' || stat || '</p>' ||
      '<table border="1" cellpadding="6" style="border-collapse:collapse"><tr style="background:#f3f4f6">' ||
      '<th>Rows in file</th><th>Loaded</th><th>Rejected</th></tr><tr><td align="right">' || parsed ||
      '</td><td align="right">' || loaded || '</td><td align="right" style="color:#b91c1c"><b>' || rejected ||
      '</b></td></tr></table>' ||
      '<h3>Why rows were rejected</h3><table border="1" cellpadding="6" style="border-collapse:collapse">' ||
      '<tr style="background:#f3f4f6"><th>Reason</th><th>Column</th><th>Rows</th></tr>' || COALESCE(reasons, '') || '</table>' ||
      '<h3>Rejected rows (first 20)</h3><table border="1" cellpadding="6" style="border-collapse:collapse">' ||
      '<tr style="background:#f3f4f6"><th>Line</th><th>Column</th><th>Error</th><th>Original record</th></tr>' ||
      COALESCE(rows_html, '') || '</table>' ||
      '<p style="margin-top:16px"><a href="' || url || '" style="background:#29B5E8;color:#fff;padding:10px 16px;' ||
      'text-decoration:none;border-radius:4px">Download all rejected rows (CSV)</a> ' ||
      '<span style="color:#666">link valid for 7 days</span></p>' ||
      '<p style="color:#555">The ' || loaded || ' good rows are already loaded and available. ' ||
      'Send the rejected lines back to the client for correction.</p></div>';

    CALL SYSTEM$SEND_EMAIL('SOMATUS_DEMO_EMAIL', 'mayank.p.gupta@snowflake.com', :subj, :body, 'text/html');

    INSERT INTO SOMATUS_DEMO.OPS.LOAD_ERROR_LOG (FILE_NAME, TABLE_NAME, ROWS_IN_FILE, ROWS_LOADED, ROWS_REJECTED, CSV_URL)
      VALUES (:fname, :tbl, :parsed, :loaded, :rejected, :url);
    sent := sent + 1;
  END FOR;
  RETURN sent || ' load error email(s) sent';
END;
$$;

-- Serverless alert (no warehouse). Kept SUSPENDED so it costs nothing between demos;
-- in the demo run EXECUTE ALERT to fire it immediately. In production: ALTER ALERT ... RESUME.
CREATE OR REPLACE ALERT SOMATUS_DEMO.OPS.ALERT_LOAD_ERRORS
  SCHEDULE = '1 MINUTE'
  IF (EXISTS (
    SELECT 1 FROM TABLE(SOMATUS_DEMO.INFORMATION_SCHEMA.COPY_HISTORY(
           TABLE_NAME => 'SOMATUS_DEMO.BRONZE.MEMBERS_RAW', START_TIME => DATEADD('hour', -1, CURRENT_TIMESTAMP()))) h
    WHERE h.ERROR_COUNT > 0
      AND NOT EXISTS (SELECT 1 FROM SOMATUS_DEMO.OPS.LOAD_ERROR_LOG l WHERE l.FILE_NAME = h.FILE_NAME)))
  THEN CALL SOMATUS_DEMO.OPS.SP_NOTIFY_LOAD_ERRORS();
