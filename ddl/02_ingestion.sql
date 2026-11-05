-- ============================================================
-- SOMATUS DEMO · 02 RELIABLE INGESTION (CSV · Avro · JSON)
-- Kenny: "large client files, different formats, new or missing columns,
--         ingestion failures, and reprocessing without duplicates"
-- S3 stands in for Azure Blob; Event Grid replaces S3 event notifications on Azure.
-- ============================================================
USE ROLE ACCOUNTADMIN;
USE WAREHOUSE WH_INGEST;
USE SCHEMA SOMATUS_DEMO.BRONZE;

-- ---------- Setup (already built) ----------
-- Stage over the client drop folder
CREATE STAGE IF NOT EXISTS S3_CLIENT_DROP URL='s3://mgupta-bucket/soybase/somatus/'
  STORAGE_INTEGRATION=S3_DATA_INTEGRATION DIRECTORY=(ENABLE=TRUE);

-- File formats: one per type. ERROR_ON_COLUMN_COUNT_MISMATCH=FALSE lets missing columns load as NULL
CREATE OR REPLACE FILE FORMAT FF_CSV  TYPE=CSV PARSE_HEADER=TRUE FIELD_OPTIONALLY_ENCLOSED_BY='"'
  NULL_IF=('') ERROR_ON_COLUMN_COUNT_MISMATCH=FALSE COMPRESSION=AUTO;
CREATE OR REPLACE FILE FORMAT FF_AVRO TYPE=AVRO;
CREATE OR REPLACE FILE FORMAT FF_JSON TYPE=JSON STRIP_OUTER_ARRAY=TRUE;

-- Bronze tables: ENABLE_SCHEMA_EVOLUTION adds new client columns automatically.
-- FILE_NAME / LOADED_AT give lineage for reconciliation and reprocessing.
--   MEMBERS_RAW (CSV), CLAIMS_RAW (Avro), LABS_RAW (JSON -> VARIANT)

-- Auto-ingest pipes: a saved COPY + S3 event listener, serverless (no warehouse)
CREATE OR REPLACE PIPE PIPE_MEMBERS AUTO_INGEST=TRUE AS
COPY INTO MEMBERS_RAW FROM @S3_CLIENT_DROP/members/
  FILE_FORMAT=(FORMAT_NAME=FF_CSV) MATCH_BY_COLUMN_NAME=CASE_INSENSITIVE
  INCLUDE_METADATA=(FILE_NAME=METADATA$FILENAME, LOADED_AT=METADATA$START_SCAN_TIME) ON_ERROR=CONTINUE;
CREATE OR REPLACE PIPE PIPE_CLAIMS AUTO_INGEST=TRUE AS
COPY INTO CLAIMS_RAW FROM @S3_CLIENT_DROP/claims/
  FILE_FORMAT=(FORMAT_NAME=FF_AVRO) MATCH_BY_COLUMN_NAME=CASE_INSENSITIVE
  INCLUDE_METADATA=(FILE_NAME=METADATA$FILENAME, LOADED_AT=METADATA$START_SCAN_TIME) ON_ERROR=CONTINUE;
CREATE OR REPLACE PIPE PIPE_LABS AUTO_INGEST=TRUE AS
COPY INTO LABS_RAW (RAW, FILE_NAME, LOADED_AT)
  FROM (SELECT $1, METADATA$FILENAME, METADATA$START_SCAN_TIME FROM @S3_CLIENT_DROP/labs/)
  FILE_FORMAT=(FORMAT_NAME=FF_JSON) ON_ERROR=CONTINUE;

-- SQS ARN to put in the S3 event notification (prefix soybase/somatus/):
SHOW PIPES IN SCHEMA SOMATUS_DEMO.BRONZE;

-- =====================  LIVE DEMO  =====================
-- Run 99_reset.sql first so Bronze is empty.

-- STEP 1 · Large file (4 x 1.25M-row CSV parts): drag members_HUMANA_*part*.csv.gz into s3://.../somatus/members/
SELECT SYSTEM$PIPE_STATUS('PIPE_MEMBERS');
SELECT FILE_NAME, STATUS, ROW_COUNT, ROW_PARSED, FIRST_ERROR_MESSAGE, LAST_LOAD_TIME
FROM TABLE(INFORMATION_SCHEMA.COPY_HISTORY(TABLE_NAME=>'MEMBERS_RAW', START_TIME=>DATEADD('hour',-1,CURRENT_TIMESTAMP())))
ORDER BY LAST_LOAD_TIME DESC;

-- STEP 2 · Schema change: drop members_AETNA_DEMO_20261022_v2.csv.gz (columns reordered + DIALYSIS_MODALITY added)
SELECT COLUMN_NAME, DATA_TYPE FROM SOMATUS_DEMO.INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_SCHEMA='BRONZE' AND TABLE_NAME='MEMBERS_RAW' ORDER BY ORDINAL_POSITION;
SELECT DIALYSIS_MODALITY, COUNT(*) FROM MEMBERS_RAW GROUP BY 1;

-- STEP 3 · Bad file: drop members_CIGNA_DEMO_20261022_bad.csv -> PARTIALLY_LOADED (90 good, 10 bad dates)
-- (re-run the COPY_HISTORY query above)
-- See exactly which rows failed and why:
SELECT * FROM TABLE(VALIDATE_PIPE_LOAD(PIPE_NAME=>'SOMATUS_DEMO.BRONZE.PIPE_MEMBERS',
                                       START_TIME=>DATEADD('hour',-1,CURRENT_TIMESTAMP())));

-- STEP 4 · Re-run / reprocess without duplicates
SELECT COUNT(*) FROM MEMBERS_RAW;                -- note the count
ALTER PIPE PIPE_MEMBERS REFRESH;                  -- ask Snowpipe to re-scan the whole folder
SELECT COUNT(*) FROM MEMBERS_RAW;                -- same count: load metadata skips already-loaded files
-- A corrected file uploaded with new content IS loaded (new checksum). Forcing a full reload is explicit:
-- COPY INTO MEMBERS_RAW FROM @S3_CLIENT_DROP/members/ ... FORCE = TRUE;

-- STEP 5 · Avro + JSON: drop claims_*.avro into /claims/ and labs_*.json into /labs/
SELECT COUNT(*), COUNT(PLACE_OF_SERVICE) AS ROWS_WITH_NEW_V2_FIELD FROM CLAIMS_RAW;
SELECT RAW FROM LABS_RAW LIMIT 3;                 -- nested JSON kept intact in VARIANT
SELECT RAW:panel.results[0].test::STRING, RAW:panel.results[0].value::FLOAT FROM LABS_RAW LIMIT 5;

-- Note: VALIDATION_MODE (dry run) works for positional COPY, not with MATCH_BY_COLUMN_NAME.
