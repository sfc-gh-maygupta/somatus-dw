-- ============================================================
-- SOMATUS DEMO · 05 DATA QUALITY & RECONCILIATION
-- Kenny: "validating incoming data, identifying duplicate or invalid records,
--         and reconciling source-to-target results"
-- ============================================================
USE ROLE ACCOUNTADMIN;
USE WAREHOUSE WH_TRANSFORM;

-- ---------- Data Metric Functions: checks attached to the table ----------
-- Built-in: NULL_COUNT, ROW_COUNT, FRESHNESS.  Custom: DMF_INVALID_EGFR, DMF_DUP_LAB_KEY
SHOW DATA METRIC FUNCTIONS IN SCHEMA SOMATUS_DEMO.OPS;
-- Custom rule is just SQL:  SELECT COUNT_IF(TEST='eGFR' AND (RESULT_VALUE < 0 OR RESULT_VALUE > 150)) FROM t

-- What's attached to Silver lab results, and on what schedule:
SELECT METRIC_NAME, REF_ARGUMENTS, SCHEDULE, SCHEDULE_STATUS
FROM TABLE(SOMATUS_DEMO.INFORMATION_SCHEMA.DATA_METRIC_FUNCTION_REFERENCES(
       REF_ENTITY_NAME => 'SOMATUS_DEMO.SILVER.LAB_RESULTS', REF_ENTITY_DOMAIN => 'TABLE'));

-- Run the checks now and see which expectations are violated:
SELECT METRIC_NAME, EXPECTATION_NAME, EXPECTATION_EXPRESSION, VALUE, EXPECTATION_VIOLATED
FROM TABLE(SYSTEM$EVALUATE_DATA_QUALITY_EXPECTATIONS(REF_ENTITY_NAME => 'SOMATUS_DEMO.SILVER.LAB_RESULTS'));

-- Scheduled results history (populates every 5 min; also visible in Snowsight > table > Data Quality tab):
SELECT MEASUREMENT_TIME, METRIC_NAME, VALUE
FROM SNOWFLAKE.LOCAL.DATA_QUALITY_MONITORING_RESULTS
WHERE TABLE_DATABASE = 'SOMATUS_DEMO' AND TABLE_NAME = 'LAB_RESULTS'
ORDER BY MEASUREMENT_TIME DESC LIMIT 20;

-- ---------- Quarantine: bad rows are kept with a reason, never silently dropped ----------
-- SILVER.LAB_RESULTS_CHECKED tags each row; _VALID feeds Gold; _QUARANTINE is for review
SELECT REJECT_REASON, COUNT(*) FROM SOMATUS_DEMO.SILVER.LAB_RESULTS_QUARANTINE GROUP BY 1 ORDER BY 2 DESC;
SELECT LAB_ID, MEMBER_ID, TEST, RESULT_VALUE, REJECT_REASON, FILE_NAME
FROM SOMATUS_DEMO.SILVER.LAB_RESULTS_QUARANTINE LIMIT 10;

-- ---------- Source-to-target reconciliation per file ----------
-- file rows -> loaded -> Bronze -> Silver (exploded) -> valid + quarantined
SELECT * FROM SOMATUS_DEMO.OPS.RECON_LAB_FILES;

-- Members: rejected-at-load rows from the bad CIGNA file show up here too
SELECT FILE_NAME, STATUS, ROW_PARSED, ROW_COUNT AS LOADED, ERROR_COUNT, FIRST_ERROR_MESSAGE
FROM TABLE(SOMATUS_DEMO.INFORMATION_SCHEMA.COPY_HISTORY(
       TABLE_NAME => 'SOMATUS_DEMO.BRONZE.MEMBERS_RAW', START_TIME => DATEADD('day', -1, CURRENT_TIMESTAMP())));
