-- ============================================================
-- SOMATUS DEMO · 01 CONCURRENCY & WORKLOAD ISOLATION
-- Kenny's #1: "large daily file loads, sync processes, and reporting stored
-- procedures experience significant slowdowns when running simultaneously"
-- ============================================================
USE ROLE ACCOUNTADMIN;
USE SCHEMA SOMATUS_DEMO.OPS;

-- What's in play: 100M claims, 2M members (synthetic)
SELECT (SELECT COUNT(*) FROM SOMATUS_DEMO.SILVER.CLAIMS) AS CLAIMS,
       (SELECT COUNT(*) FROM SOMATUS_DEMO.SILVER.MEMBERS) AS MEMBERS;

-- The three jobs: SP_DAILY_LOAD (30M-row load), SP_BUILD_REPORTING (heavy join/agg SP),
-- SP_BI_BURST(20) (20 parallel Power BI-style queries)
SHOW WAREHOUSES LIKE 'WH_%';

-- ---------- ACT 1: "Your Synapse today" - one shared pool ----------
EXECUTE TASK T_SHARED_LOAD;
EXECUTE TASK T_SHARED_REPORTING;
EXECUTE TASK T_SHARED_BI;
-- Open Snowsight > Monitoring > Query History, filter warehouse WH_SHARED_SYNAPSE_SIM: see "Queued"

-- ---------- ACT 2: same jobs, one warehouse each ----------
ALTER WAREHOUSE WH_BI SET MAX_CLUSTER_COUNT = 1;   -- isolation only, no scale-out yet
EXECUTE TASK T_ISO_LOAD;
EXECUTE TASK T_ISO_REPORTING;
EXECUTE TASK T_ISO_BI;

-- ---------- ACT 3: Power BI peak -> multi-cluster scale-out ----------
ALTER WAREHOUSE WH_BI SET MAX_CLUSTER_COUNT = 4;
EXECUTE TASK T_ISO_BI;
SHOW WAREHOUSES LIKE 'WH_BI';            -- watch "started_clusters" go above 1

-- ---------- PROOF: time spent waiting vs working ----------
SELECT WAREHOUSE_NAME, COUNT(*) QUERIES,
       ROUND(SUM(QUEUED_OVERLOAD_TIME)/1000,1) QUEUED_SECS,
       ROUND(AVG(EXECUTION_TIME)/1000,1)        AVG_EXEC_SECS,
       ROUND(MAX(TOTAL_ELAPSED_TIME)/1000,1)    MAX_ELAPSED_SECS
FROM TABLE(SOMATUS_DEMO.INFORMATION_SCHEMA.QUERY_HISTORY(
       END_TIME_RANGE_START => DATEADD('minute', -20, CURRENT_TIMESTAMP()), RESULT_LIMIT => 1000))
WHERE WAREHOUSE_NAME IN ('WH_SHARED_SYNAPSE_SIM','WH_INGEST','WH_TRANSFORM','WH_BI')
  AND QUERY_TYPE IN ('INSERT','CREATE_TABLE_AS_SELECT')
GROUP BY 1 ORDER BY 1;

-- ---------- Bonus: scale UP for one heavy proc, then back down ----------
ALTER WAREHOUSE WH_TRANSFORM SET WAREHOUSE_SIZE = 'XLARGE';
CALL SP_BUILD_REPORTING();
ALTER WAREHOUSE WH_TRANSFORM SET WAREHOUSE_SIZE = 'LARGE';

-- ---------- Readers are never blocked by writers ----------
-- While T_ISO_LOAD is inserting, this returns instantly from a consistent snapshot:
SELECT COUNT(*) FROM SOMATUS_DEMO.BRONZE.CLAIMS_DAILY_LOAD;
