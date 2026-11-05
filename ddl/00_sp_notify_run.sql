CREATE OR REPLACE PROCEDURE "SP_NOTIFY_RUN"()
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS OWNER
AS '
DECLARE
  grp STRING;
  failed_count INT;
  summary STRING;
  published INT;
BEGIN
  grp := (SELECT SYSTEM$TASK_RUNTIME_INFO(''CURRENT_TASK_GRAPH_RUN_GROUP_ID''));
  WITH latest AS (
    SELECT NAME, STATE, ERROR_MESSAGE
    FROM TABLE(SOMATUS_DEMO.INFORMATION_SCHEMA.TASK_HISTORY(SCHEDULED_TIME_RANGE_START => DATEADD(''hour'', -2, CURRENT_TIMESTAMP())))
    WHERE GRAPH_RUN_GROUP_ID = :grp AND NAME <> ''T_NOTIFY'' AND STATE IN (''SUCCEEDED'',''FAILED'',''CANCELLED'')
    QUALIFY ROW_NUMBER() OVER (PARTITION BY NAME ORDER BY ATTEMPT_NUMBER DESC) = 1)
  SELECT COUNT_IF(STATE <> ''SUCCEEDED''),
         LISTAGG(NAME || '': '' || STATE || IFF(ERROR_MESSAGE IS NULL, '''', '' - '' || ERROR_MESSAGE), ''\\n'')
    INTO :failed_count, :summary FROM latest;

  IF (failed_count > 0) THEN
    CALL SYSTEM$SEND_EMAIL(''SOMATUS_DEMO_EMAIL'', ''mayank.p.gupta@snowflake.com'',
      ''[Somatus demo] PIPELINE FAILED - claims daily load'',
      ''Task graph run '' || :grp || '' failed.\\n\\n'' || :summary || ''\\n\\nFix the issue, then run: EXECUTE TASK SOMATUS_DEMO.OPS.T_ROOT RETRY LAST;'');
    INSERT INTO SOMATUS_DEMO.OPS.PIPELINE_LOG (STEP, STATUS, DETAIL) VALUES (''NOTIFY'', ''ALERT_SENT'', :summary);
    RETURN ''failure alert sent'';
  END IF;

  -- All steps succeeded: send a short success email too
  SELECT COUNT(*) INTO :published FROM SOMATUS_DEMO.GOLD.CLAIMS_PUBLISHED;
  CALL SYSTEM$SEND_EMAIL(''SOMATUS_DEMO_EMAIL'', ''mayank.p.gupta@snowflake.com'',
    ''[Somatus demo] PIPELINE SUCCEEDED - claims daily load'',
    ''Task graph run '' || :grp || '' succeeded.\\n\\n'' || :summary || ''\\n\\nGold CLAIMS_PUBLISHED now has '' || :published || '' rows.'');
  INSERT INTO SOMATUS_DEMO.OPS.PIPELINE_LOG (STEP, STATUS, DETAIL) VALUES (''NOTIFY'', ''SUCCESS_SENT'', :summary);
  RETURN ''success email sent'';
END;
';
