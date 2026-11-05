-- ============================================================
-- SOMATUS DEMO · 06 COST BY WORKLOAD AND BY CLIENT
-- Kenny: "understand cost tracking by workload or client"
-- Note: ACCOUNT_USAGE views lag (metering ~3h, tag refs ~2h, query attribution ~8h)
-- ============================================================
USE ROLE ACCOUNTADMIN;
USE WAREHOUSE WH_INGEST;

-- ---------- How it's tagged ----------
-- Warehouses carry a WORKLOAD tag; every job carries QUERY_TAG='client=...;workload=...'
SELECT SYSTEM$GET_TAG('SOMATUS_DEMO.OPS.WORKLOAD', 'WH_TRANSFORM', 'WAREHOUSE');
SHOW TASKS LIKE 'T_CLIENT_%' IN SCHEMA SOMATUS_DEMO.OPS;   -- see query_tag column

-- ---------- 1 · Cost by workload (one warehouse per workload) ----------
SELECT COALESCE(t.TAG_VALUE, 'untagged') AS WORKLOAD, m.WAREHOUSE_NAME,
       ROUND(SUM(m.CREDITS_USED), 3) AS CREDITS
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY m
LEFT JOIN SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES t
  ON t.DOMAIN = 'WAREHOUSE' AND t.OBJECT_NAME = m.WAREHOUSE_NAME
 AND t.TAG_NAME = 'WORKLOAD' AND t.TAG_DATABASE = 'SOMATUS_DEMO'
WHERE m.START_TIME >= DATEADD('day', -7, CURRENT_TIMESTAMP())
  AND m.WAREHOUSE_NAME LIKE 'WH\\_%' ESCAPE '\\'
GROUP BY 1, 2 ORDER BY 3 DESC;

-- ---------- 2 · Cost by client (per-query credit attribution, even on a shared warehouse) ----------
SELECT REGEXP_SUBSTR(QUERY_TAG, 'client=([A-Z_]+)', 1, 1, 'e')  AS CLIENT,
       REGEXP_SUBSTR(QUERY_TAG, 'workload=([a-z]+)', 1, 1, 'e') AS WORKLOAD,
       COUNT(*) AS QUERIES,
       ROUND(SUM(CREDITS_ATTRIBUTED_COMPUTE), 4) AS CREDITS
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY
WHERE START_TIME >= DATEADD('day', -7, CURRENT_TIMESTAMP())
  AND WAREHOUSE_NAME LIKE 'WH\\_%' ESCAPE '\\'
GROUP BY 1, 2 ORDER BY CREDITS DESC;

-- Same thing as $ (demo rate; Somatus contract rate would apply)
SELECT REGEXP_SUBSTR(QUERY_TAG, 'client=([A-Z_]+)', 1, 1, 'e') AS CLIENT,
       ROUND(SUM(CREDITS_ATTRIBUTED_COMPUTE), 4) AS CREDITS,
       ROUND(SUM(CREDITS_ATTRIBUTED_COMPUTE) * 4.00, 2) AS EST_USD_AT_4_PER_CREDIT
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY
WHERE START_TIME >= DATEADD('day', -7, CURRENT_TIMESTAMP()) AND QUERY_TAG ILIKE '%client=%'
GROUP BY 1 ORDER BY 2 DESC;

-- ---------- 3 · Serverless costs too (Snowpipe, dynamic tables, DMFs) ----------
SELECT SERVICE_TYPE, ROUND(SUM(CREDITS_USED), 3) AS CREDITS
FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY
WHERE START_TIME >= DATEADD('day', -7, CURRENT_TIMESTAMP())
GROUP BY 1 ORDER BY 2 DESC;
SELECT PIPE_NAME, ROUND(SUM(CREDITS_USED), 4) AS CREDITS, SUM(FILES_INSERTED) AS FILES
FROM SNOWFLAKE.ACCOUNT_USAGE.PIPE_USAGE_HISTORY
WHERE START_TIME >= DATEADD('day', -7, CURRENT_TIMESTAMP()) GROUP BY 1;

-- ---------- 4 · Guardrails: budget with email alerts ----------
CALL SOMATUS_DEMO.OPS.SOMATUS_DE_BUDGET!GET_SPENDING_LIMIT();
CALL SOMATUS_DEMO.OPS.SOMATUS_DE_BUDGET!GET_LINKED_RESOURCES();
-- Snowsight: Admin > Cost Management > Budgets  (visual spend vs limit, forecast)
