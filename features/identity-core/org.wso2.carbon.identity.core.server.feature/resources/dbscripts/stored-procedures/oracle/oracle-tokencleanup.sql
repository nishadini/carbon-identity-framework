CREATE OR REPLACE PROCEDURE WSO2_TOKEN_CLEANUP_SP IS

-- ------------------------------------------
-- VARIABLE DECLARATION
-- ------------------------------------------

systime TIMESTAMP := systimestamp;
utcTime TIMESTAMP := sys_extract_utc(systimestamp);
deleteCount INT := 0;
chunkCount INT := 0;
batchCount INT := 0;
ROWCOUNT INT := 0;
cleaupCount INT := 0;
maxValidityPeriod INT := 99999999999990;  -- IF THE VALIDITY PERIOD IS MORE THAN 3170.97 YEARS WILL SKIP THE CLEANUP PROCESS;
CURRENT_SCHEMA VARCHAR(20);
backupTable VARCHAR(50);
cursorTable VARCHAR(50);

CURSOR backupTablesCursor is
SELECT TABLE_NAME FROM ALL_TABLES WHERE OWNER = CURRENT_SCHEMA AND
TABLE_NAME IN ('IDN_OAUTH2_ACCESS_TOKEN', 'IDN_OAUTH2_AUTHORIZATION_CODE', 'IDN_OAUTH2_ACCESS_TOKEN_SCOPE','IDN_OIDC_REQ_OBJECT_REFERENCE','IDN_OIDC_REQ_OBJECT_CLAIMS','IDN_OIDC_REQ_OBJ_CLAIM_VALUES');

-- ------------------------------------------
-- CONFIGURABLE ATTRIBUTES
-- ------------------------------------------

batchSize INT := 10000; -- BATCH WISE DELETE [DEFULT : 10000]
chunkSize INT := 500000; -- CHUNK WISE DELETE FOR LARGE TABLES [DEFULT : 500000]
backupTables BOOLEAN := TRUE;  -- SET IF TOKEN TABLE NEEDS TO BACKUP BEFORE DELETE [DEFAULT : TRUE] , WILL DROP THE PREVIOUS BACKUP TABLES IN NEXT ITERATION
sleepTime FLOAT :=2;  -- SET SLEEP TIME FOR AVOID TABLE LOCKS     [DEFAULT : 2]
safePeriod INT := 2; -- SET SLEEP TIME FOR AVOID TABLE LOCKS     [DEFAULT 2 in hours]
deleteTimeLimit TIMESTAMP := utcTime-safePeriod/24; -- SET CURRENT TIME - safePeriod FOR BEGIN THE TOKEN DELETE
enableLog BOOLEAN := TRUE ; -- ENABLE LOGGING [DEFAULT : TRUE]
logLevel VARCHAR(10) := 'TRACE'; -- SET LOG LEVELS : TRACE , DEBUG
enableAudit BOOLEAN := TRUE; -- SET TRUE FOR  KEEP TRACK OF ALL THE DELETED TOKENS USING A TABLE    [DEFAULT : TRUE] [# IF YOU ENABLE THIS TABLE BACKUP WILL FORCEFULLY SET TO TRUE]
enableStsGthrn BOOLEAN := FALSE; -- SET TRUE FOR GATHER SCHEMA LEVEL STATS TO IMPROVE QUERY PERFOMANCE [DEFAULT : FALSE]
enableRebuildIndexes BOOLEAN := FASLE; -- SET TRUE FOR REBUILD INDEXES TO IMPROVE QUERY PERFOMANCE [DEFAULT : FALSE]


BEGIN

-- ------------------------------------------------------
-- CREATING LOG TABLE IDN_OAUTH2_ACCESS_TOKEN
-- ------------------------------------------------------

SELECT SYS_CONTEXT( 'USERENV', 'CURRENT_SCHEMA' ) INTO CURRENT_SCHEMA FROM DUAL;

IF (enableLog)
THEN
SELECT COUNT(*) INTO ROWCOUNT from ALL_TABLES where OWNER = CURRENT_SCHEMA AND table_name = upper('LOG_WSO2_TOKEN_CLEANUP_SP');
    IF (ROWCOUNT = 1) then
    EXECUTE IMMEDIATE 'DROP TABLE LOG_WSO2_TOKEN_CLEANUP_SP';
    COMMIT;
    END if;
EXECUTE IMMEDIATE 'CREATE TABLE LOG_WSO2_TOKEN_CLEANUP_SP (TIMESTAMP VARCHAR(250) , LOG VARCHAR(250)) NOLOGGING';
COMMIT;
EXECUTE IMMEDIATE 'INSERT INTO LOG_WSO2_TOKEN_CLEANUP_SP (TIMESTAMP,LOG) VALUES (TO_CHAR( SYSTIMESTAMP, ''DD.MM.YYYY HH24:MI:SS:FF4''),''WSO2_TOKEN_CLEANUP_SP STARTED .... !'')';
EXECUTE IMMEDIATE 'INSERT INTO LOG_WSO2_TOKEN_CLEANUP_SP (TIMESTAMP,LOG) VALUES (TO_CHAR( SYSTIMESTAMP, ''DD.MM.YYYY HH24:MI:SS:FF4''),'' '')';
EXECUTE IMMEDIATE 'INSERT INTO LOG_WSO2_TOKEN_CLEANUP_SP (TIMESTAMP,LOG) VALUES (TO_CHAR( SYSTIMESTAMP, ''DD.MM.YYYY HH24:MI:SS:FF4''),''USING SCHEMA :'||CURRENT_SCHEMA||''')';
COMMIT;
END IF;


IF (enableAudit)
THEN
backupTables := TRUE;    -- BACKUP TABLES IS REQUIRED BE TRUE, HENCE THE AUDIT IS ENABLED.
END IF;

-- ------------------------------------------------------
-- BACKUP TABLES
-- ------------------------------------------------------


IF (backupTables)
THEN
      IF (enableLog)
      THEN
          EXECUTE IMMEDIATE 'INSERT INTO LOG_WSO2_TOKEN_CLEANUP_SP (TIMESTAMP,LOG) VALUES (TO_CHAR( SYSTIMESTAMP, ''DD.MM.YYYY HH24:MI:SS:FF4''),''TABLE BACKUP STARTED ... !'')';
          COMMIT;
      END IF;

      FOR cursorTable IN backupTablesCursor
      LOOP

      SELECT REPLACE(''||cursorTable.TABLE_NAME||'','IDN_','BAK_') INTO backupTable FROM DUAL;

      IF (enableLog AND logLevel IN ('TRACE'))
      THEN
          EXECUTE IMMEDIATE 'INSERT INTO LOG_WSO2_TOKEN_CLEANUP_SP (TIMESTAMP,LOG) VALUES (TO_CHAR( SYSTIMESTAMP, ''DD.MM.YYYY HH24:MI:SS:FF4''),''BACKING UP '||cursorTable.TABLE_NAME||' INTO '||backupTable||' STARTED '')';
          COMMIT;
      END IF;

      SELECT COUNT(*) INTO ROWCOUNT from ALL_TABLES where OWNER = CURRENT_SCHEMA AND table_name = upper(backupTable);
      IF (ROWCOUNT = 1)
      THEN
          EXECUTE IMMEDIATE 'DROP TABLE '||backupTable;
          COMMIT;
      END if;

      EXECUTE IMMEDIATE 'CREATE TABLE '||backupTable||' AS (SELECT * FROM '||cursorTable.TABLE_NAME||')';
      ROWCOUNT:= sql%rowcount;
      COMMIT;

      IF (enableLog  AND logLevel IN ('TRACE','DEBUG') )
      THEN
          EXECUTE IMMEDIATE 'INSERT INTO LOG_WSO2_TOKEN_CLEANUP_SP (TIMESTAMP,LOG) VALUES (TO_CHAR( SYSTIMESTAMP, ''DD.MM.YYYY HH24:MI:SS:FF4''),''BACKING UP '||cursorTable.TABLE_NAME||' COMPLETED WITH : '||ROWCOUNT||''')';
          COMMIT;
      END IF;

      END LOOP;
      IF (enableLog)
      THEN
          EXECUTE IMMEDIATE 'INSERT INTO LOG_WSO2_TOKEN_CLEANUP_SP (TIMESTAMP,LOG) VALUES (TO_CHAR( SYSTIMESTAMP, ''DD.MM.YYYY HH24:MI:SS:FF4''),'' '')';
          COMMIT;
      END IF;
END IF;


-- ------------------------------------------------------
-- CREATING AUDIT TABLES FOR TOKENS DELETION FOR THE FIRST TIME RUN
-- ------------------------------------------------------
IF (enableAudit)
THEN

    SELECT count(1) into ROWCOUNT FROM ALL_TABLES where OWNER = CURRENT_SCHEMA AND table_name = 'ADT_OAUTH2_ACCESS_TOKEN';
    IF (ROWCOUNT =0 )
    THEN
        IF (enableLog  AND logLevel IN ('TRACE') )
        THEN
            EXECUTE IMMEDIATE 'INSERT INTO LOG_WSO2_TOKEN_CLEANUP_SP (TIMESTAMP,LOG) VALUES (TO_CHAR( SYSTIMESTAMP, ''DD.MM.YYYY HH24:MI:SS:FF4''),''CREATING AUDIT TABLE ADT_OAUTH2_ACCESS_TOKEN .. ! '')';
            COMMIT;
        END IF;
        EXECUTE IMMEDIATE 'CREATE TABLE ADT_OAUTH2_ACCESS_TOKEN as (SELECT * FROM IDN_OAUTH2_ACCESS_TOKEN WHERE 1 = 2)';
        COMMIT;
    ELSE
        IF (enableLog  AND logLevel IN ('TRACE') )
        THEN
            EXECUTE IMMEDIATE 'INSERT INTO LOG_WSO2_TOKEN_CLEANUP_SP (TIMESTAMP,LOG) VALUES (TO_CHAR( SYSTIMESTAMP, ''DD.MM.YYYY HH24:MI:SS:FF4''),''USING AUDIT TABLE ADT_OAUTH2_ACCESS_TOKEN'')';
            COMMIT;
        END IF;
    END IF;

    SELECT count(1) into ROWCOUNT FROM ALL_TABLES where OWNER = CURRENT_SCHEMA AND table_name = 'ADT_OAUTH2_AUTHORIZATION_CODE';
    IF (ROWCOUNT = 0)
    THEN
        IF (enableLog  AND logLevel IN ('TRACE') )
        THEN
            EXECUTE IMMEDIATE 'INSERT INTO LOG_WSO2_TOKEN_CLEANUP_SP (TIMESTAMP,LOG) VALUES (TO_CHAR( SYSTIMESTAMP, ''DD.MM.YYYY HH24:MI:SS:FF4''),''CREATING AUDIT TABLE ADT_OAUTH2_AUTHORIZATION_CODE .. ! '')';
            COMMIT;
        END IF;
        EXECUTE IMMEDIATE 'CREATE TABLE ADT_OAUTH2_AUTHORIZATION_CODE as (SELECT * FROM IDN_OAUTH2_AUTHORIZATION_CODE WHERE 1 = 2)';
        COMMIT;
    ELSE
        IF (enableLog  AND logLevel IN ('TRACE'))
        THEN
            EXECUTE IMMEDIATE 'INSERT INTO LOG_WSO2_TOKEN_CLEANUP_SP (TIMESTAMP,LOG) VALUES (TO_CHAR( SYSTIMESTAMP, ''DD.MM.YYYY HH24:MI:SS:FF4''),''USING AUDIT TABLE ADT_OAUTH2_AUTHORIZATION_CODE'')';
            COMMIT;
        END IF;
    END IF;
      IF (enableLog  AND logLevel IN ('TRACE'))
      THEN
        EXECUTE IMMEDIATE 'INSERT INTO LOG_WSO2_TOKEN_CLEANUP_SP (TIMESTAMP,LOG) VALUES (TO_CHAR( SYSTIMESTAMP, ''DD.MM.YYYY HH24:MI:SS:FF4''),'' '')';
        COMMIT;
      END IF;

END IF;


---- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
---- CALCULATING TOKENS TYPES IN IDN_OAUTH2_ACCESS_TOKEN
---- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
IF (enableLog)
THEN
    EXECUTE IMMEDIATE 'INSERT INTO LOG_WSO2_TOKEN_CLEANUP_SP (TIMESTAMP,LOG) VALUES (TO_CHAR( SYSTIMESTAMP, ''DD.MM.YYYY HH24:MI:SS:FF4''),''CALCULATING TOKENS TYPES IN IDN_OAUTH2_ACCESS_TOKEN TABLE .... !'')';
    COMMIT;

    IF (enableLog AND logLevel IN ('DEBUG','TRACE'))
    THEN
        SELECT COUNT(1) INTO ROWCOUNT FROM IDN_OAUTH2_ACCESS_TOKEN;
        EXECUTE IMMEDIATE 'INSERT INTO LOG_WSO2_TOKEN_CLEANUP_SP (TIMESTAMP,LOG) VALUES (TO_CHAR( SYSTIMESTAMP, ''DD.MM.YYYY HH24:MI:SS:FF4''),''TOTAL TOKENS ON IDN_OAUTH2_ACCESS_TOKEN TABLE BEFORE DELETE : '||ROWCOUNT||''')';
        COMMIT;
    END IF;

    IF (enableLog AND logLevel IN ('TRACE'))
    THEN
        SELECT COUNT(1) INTO cleaupCount FROM IDN_OAUTH2_ACCESS_TOKEN WHERE TOKEN_STATE IN ('INACTIVE','REVOKED') OR
        (TOKEN_STATE in('EXPIRED','ACTIVE') AND
        (VALIDITY_PERIOD BETWEEN 0 and maxValidityPeriod) AND (REFRESH_TOKEN_VALIDITY_PERIOD BETWEEN 0 and maxValidityPeriod) AND
        (deleteTimeLimit > (TIME_CREATED +  NUMTODSINTERVAL( VALIDITY_PERIOD / 60000, 'MINUTE' ))  ) AND
        (deleteTimeLimit > (REFRESH_TOKEN_TIME_CREATED +  NUMTODSINTERVAL( REFRESH_TOKEN_VALIDITY_PERIOD / 60000, 'MINUTE' ))));
        EXECUTE IMMEDIATE 'INSERT INTO LOG_WSO2_TOKEN_CLEANUP_SP (TIMESTAMP,LOG) VALUES (TO_CHAR( SYSTIMESTAMP, ''DD.MM.YYYY HH24:MI:SS:FF4''),''TOTAL TOKENS SHOULD BE DELETED FROM IDN_OAUTH2_ACCESS_TOKEN : '||cleaupCount||''')';
        COMMIT;
    END IF;

    IF (enableLog AND logLevel IN ('TRACE'))
    THEN
        ROWCOUNT := (ROWCOUNT - cleaupCount);
        EXECUTE IMMEDIATE 'INSERT INTO LOG_WSO2_TOKEN_CLEANUP_SP (TIMESTAMP,LOG) VALUES (TO_CHAR( SYSTIMESTAMP, ''DD.MM.YYYY HH24:MI:SS:FF4''),''TOTAL TOKENS SHOULD BE RETAIN IN IDN_OAUTH2_ACCESS_TOKEN : '||ROWCOUNT||''')';
        COMMIT;
    END IF;
END IF;

-- ------------------------------------------------------
-- BATCH DELETE IDN_OAUTH2_ACCESS_TOKEN
-- ------------------------------------------------------
IF (enableLog)
THEN
    EXECUTE IMMEDIATE 'INSERT INTO LOG_WSO2_TOKEN_CLEANUP_SP (TIMESTAMP,LOG) VALUES (TO_CHAR( SYSTIMESTAMP, ''DD.MM.YYYY HH24:MI:SS:FF4''),'' '')';
    EXECUTE IMMEDIATE 'INSERT INTO LOG_WSO2_TOKEN_CLEANUP_SP (TIMESTAMP,LOG) VALUES (TO_CHAR( SYSTIMESTAMP, ''DD.MM.YYYY HH24:MI:SS:FF4''),''TOKEN DELETE ON IDN_OAUTH2_ACCESS_TOKEN TABLE STARTED ... ! '')';
    COMMIT;
END IF;

LOOP
      SELECT COUNT(*) INTO ROWCOUNT from ALL_TABLES where OWNER = CURRENT_SCHEMA AND table_name = upper('CHUNK_IDN_OAUTH2_ACCESS_TOKEN');
      IF (ROWCOUNT = 1) then
          EXECUTE IMMEDIATE 'DROP TABLE CHUNK_IDN_OAUTH2_ACCESS_TOKEN';
          COMMIT;
      END if;

      EXECUTE IMMEDIATE 'CREATE TABLE CHUNK_IDN_OAUTH2_ACCESS_TOKEN (ROW_ID rowid,CONSTRAINT CHNK_IDN_OATH_ACCS_TOK_PRI PRIMARY KEY (ROW_ID)) NOLOGGING';
      COMMIT;
      EXECUTE IMMEDIATE 'INSERT /*+ APPEND */ INTO CHUNK_IDN_OAUTH2_ACCESS_TOKEN (ROW_ID) SELECT rowid FROM IDN_OAUTH2_ACCESS_TOKEN WHERE rownum <= :chkSize AND (TOKEN_STATE IN (''INACTIVE'',''REVOKED'') OR
      (TOKEN_STATE in (''EXPIRED'',''ACTIVE'') AND (VALIDITY_PERIOD BETWEEN 0 and :mxValdPrid) AND (REFRESH_TOKEN_VALIDITY_PERIOD BETWEEN 0 and :mxValdPrid) AND
      ( :dtl > (TIME_CREATED +  NUMTODSINTERVAL( VALIDITY_PERIOD / 60000, ''MINUTE'' )) ) AND
      ( :dtl > (REFRESH_TOKEN_TIME_CREATED +  NUMTODSINTERVAL( REFRESH_TOKEN_VALIDITY_PERIOD / 60000, ''MINUTE'' )))))' using chunkSize,maxValidityPeriod,maxValidityPeriod,deleteTimeLimit,deleteTimeLimit;
      chunkCount:=  sql%Rowcount;
      COMMIT;

      EXIT WHEN chunkCount = 0 ;

      IF (enableLog AND logLevel IN ('TRACE'))
      THEN
          EXECUTE IMMEDIATE 'INSERT INTO LOG_WSO2_TOKEN_CLEANUP_SP (TIMESTAMP,LOG) VALUES (TO_CHAR( SYSTIMESTAMP, ''DD.MM.YYYY HH24:MI:SS:FF4''),''CHUNK TABLE CHUNK_IDN_OAUTH2_ACCESS_TOKEN CREATED WITH : '||chunkCount||''')';
          COMMIT;
      END IF;

      IF (enableAudit)
      THEN
          EXECUTE IMMEDIATE 'INSERT INTO ADT_OAUTH2_ACCESS_TOKEN SELECT TOK.* FROM IDN_OAUTH2_ACCESS_TOKEN TOK , CHUNK_IDN_OAUTH2_ACCESS_TOKEN CHK WHERE TOK.ROWID=CHK.ROW_ID';
          COMMIT;
      END IF;

      LOOP
          SELECT COUNT(*) INTO ROWCOUNT from ALL_TABLES where OWNER = CURRENT_SCHEMA AND table_name = upper('BATCH_IDN_OAUTH2_ACCESS_TOKEN');
          IF (ROWCOUNT = 1) then
              EXECUTE IMMEDIATE 'DROP TABLE BATCH_IDN_OAUTH2_ACCESS_TOKEN';
              COMMIT;
          END IF;

          EXECUTE IMMEDIATE 'CREATE TABLE BATCH_IDN_OAUTH2_ACCESS_TOKEN (ROW_ID rowid,CONSTRAINT BATCH_IDN_OATH_ACCS_TOK_PRI PRIMARY KEY (ROW_ID)) NOLOGGING';
          COMMIT;

          EXECUTE IMMEDIATE 'INSERT /*+ APPEND */ INTO BATCH_IDN_OAUTH2_ACCESS_TOKEN (ROW_ID) SELECT ROW_ID FROM CHUNK_IDN_OAUTH2_ACCESS_TOKEN WHERE rownum <= '||batchSize||'';
          batchCount:= sql%rowcount;
          COMMIT;

          EXIT WHEN batchCount = 0 ;

          IF (enableLog AND logLevel IN ('TRACE'))
              THEN
              EXECUTE IMMEDIATE 'INSERT INTO LOG_WSO2_TOKEN_CLEANUP_SP (TIMESTAMP,LOG) VALUES (TO_CHAR( SYSTIMESTAMP, ''DD.MM.YYYY HH24:MI:SS:FF4''),''BATCH DELETE START ON TABLE IDN_OAUTH2_ACCESS_TOKEN WITH : '||batchCount||''')';
              COMMIT;
          END IF;

          IF ((batchCount > 0))
          THEN
              EXECUTE IMMEDIATE 'DELETE IDN_OAUTH2_ACCESS_TOKEN where rowid in (select ROW_ID from  BATCH_IDN_OAUTH2_ACCESS_TOKEN)';
              deleteCount:= sql%rowcount;
          COMMIT;
          END IF;

          IF (enableLog)
          THEN
              EXECUTE IMMEDIATE 'INSERT INTO LOG_WSO2_TOKEN_CLEANUP_SP (TIMESTAMP,LOG) VALUES (TO_CHAR( SYSTIMESTAMP, ''DD.MM.YYYY HH24:MI:SS:FF4''),''BATCH DELETE FINISHED ON IDN_OAUTH2_ACCESS_TOKEN WITH : '||deleteCount||''')';
              COMMIT;
          END IF;

          EXECUTE IMMEDIATE 'DELETE CHUNK_IDN_OAUTH2_ACCESS_TOKEN WHERE ROW_ID in (select ROW_ID from BATCH_IDN_OAUTH2_ACCESS_TOKEN)';
          COMMIT;

          IF (enableLog AND logLevel IN ('TRACE'))
          THEN
              EXECUTE IMMEDIATE 'INSERT INTO LOG_WSO2_TOKEN_CLEANUP_SP (TIMESTAMP,LOG) VALUES (TO_CHAR( SYSTIMESTAMP, ''DD.MM.YYYY HH24:MI:SS:FF4''),''DELETED BATCH ON  CHUNK_IDN_OAUTH2_ACCESS_TOKEN !'')';
              COMMIT;
          END IF;

          IF ((deleteCount > 0))
          THEN
              IF (enableLog AND logLevel IN ('TRACE'))
              THEN
              EXECUTE IMMEDIATE 'INSERT INTO LOG_WSO2_TOKEN_CLEANUP_SP (TIMESTAMP,LOG) VALUES (TO_CHAR( SYSTIMESTAMP, ''DD.MM.YYYY HH24:MI:SS:FF4''),''SLEEPING ...'')';
              COMMIT;
              END IF;
          DBMS_LOCK.SLEEP(sleepTime);
          END IF;
      END LOOP;
END LOOP;

IF (enableLog)
THEN
    EXECUTE IMMEDIATE 'INSERT INTO LOG_WSO2_TOKEN_CLEANUP_SP (TIMESTAMP,LOG) VALUES (TO_CHAR( SYSTIMESTAMP, ''DD.MM.YYYY HH24:MI:SS:FF4''),''BATCH DELETE ON IDN_OAUTH2_ACCESS_TOKEN COMPLETED .... !'')';
    EXECUTE IMMEDIATE 'INSERT INTO LOG_WSO2_TOKEN_CLEANUP_SP (TIMESTAMP,LOG) VALUES (TO_CHAR( SYSTIMESTAMP, ''DD.MM.YYYY HH24:MI:SS:FF4''),'' '')';
END IF;
COMMIT;

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- CALCULATING CODE TYPES IN IDN_OAUTH2_AUTHORIZATION_CODE
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
IF (enableLog )
THEN
    EXECUTE IMMEDIATE 'INSERT INTO LOG_WSO2_TOKEN_CLEANUP_SP (TIMESTAMP,LOG) VALUES (TO_CHAR( SYSTIMESTAMP, ''DD.MM.YYYY HH24:MI:SS:FF4''),''CALCULATING CODE TYPES IN IDN_OAUTH2_AUTHORIZATION_CODE TABLE .... !'')';
    COMMIT;
    IF (enableLog AND logLevel IN ('DEBUG','TRACE'))
    THEN
    SELECT count(1) into ROWCOUNT FROM IDN_OAUTH2_AUTHORIZATION_CODE;
    EXECUTE IMMEDIATE 'INSERT INTO LOG_WSO2_TOKEN_CLEANUP_SP (TIMESTAMP,LOG) VALUES (TO_CHAR( SYSTIMESTAMP, ''DD.MM.YYYY HH24:MI:SS:FF4''),''TOTAL CODES ON IDN_OAUTH2_AUTHORIZATION_CODE TABLE BEFORE DELETE : '||ROWCOUNT||''')';
    COMMIT;
    END IF;
    -- -------------
    IF (enableLog AND logLevel IN ('TRACE'))
    THEN
    SELECT COUNT(1) into cleaupCount FROM IDN_OAUTH2_AUTHORIZATION_CODE WHERE CODE_ID IN
    (SELECT CODE_ID FROM IDN_OAUTH2_AUTHORIZATION_CODE code WHERE NOT EXISTS (SELECT * FROM IDN_OAUTH2_ACCESS_TOKEN tok where tok.TOKEN_ID = code.TOKEN_ID))
    AND (VALIDITY_PERIOD < maxValidityPeriod AND deleteTimeLimit > (TIME_CREATED + NUMTODSINTERVAL( VALIDITY_PERIOD / 60000, 'MINUTE' )));

    EXECUTE IMMEDIATE 'INSERT INTO LOG_WSO2_TOKEN_CLEANUP_SP (TIMESTAMP,LOG) VALUES (TO_CHAR( SYSTIMESTAMP, ''DD.MM.YYYY HH24:MI:SS:FF4''),''TOTAL CODES SHOULD BE DELETED FROM IDN_OAUTH2_AUTHORIZATION_CODE : '||cleaupCount||''')';
    COMMIT;
    END IF;
    -- -------------
    IF (enableLog AND logLevel IN ('TRACE'))
    THEN
    ROWCOUNT := (ROWCOUNT - cleaupCount);
    EXECUTE IMMEDIATE 'INSERT INTO LOG_WSO2_TOKEN_CLEANUP_SP (TIMESTAMP,LOG) VALUES (TO_CHAR( SYSTIMESTAMP, ''DD.MM.YYYY HH24:MI:SS:FF4''),''TOTAL CODES SHOULD BE RETAIN IN IDN_OAUTH2_AUTHORIZATION_CODE : '||ROWCOUNT||''')';
    COMMIT;
    END IF;
END IF;
----

-- ------------------------------------------------------
-- BATCH DELETE IDN_OAUTH2_AUTHORIZATION_CODE
-- -- ------------------------------------------------------
IF (enableLog)
THEN
EXECUTE IMMEDIATE 'INSERT INTO LOG_WSO2_TOKEN_CLEANUP_SP (TIMESTAMP,LOG) VALUES (TO_CHAR( SYSTIMESTAMP, ''DD.MM.YYYY HH24:MI:SS:FF4''),'' '')';
EXECUTE IMMEDIATE 'INSERT INTO LOG_WSO2_TOKEN_CLEANUP_SP (TIMESTAMP,LOG) VALUES (TO_CHAR( SYSTIMESTAMP, ''DD.MM.YYYY HH24:MI:SS:FF4''),''CODES DELETE ON IDN_OAUTH2_AUTHORIZATION_CODE TABLE STARTED ... !'')';
COMMIT;
END IF;
----
LOOP
      SELECT COUNT(*) INTO ROWCOUNT from ALL_TABLES where OWNER = CURRENT_SCHEMA AND table_name = upper('CHNK_IDN_OATH_AUTHRIZATN_CODE');
      IF (ROWCOUNT = 1) then
      EXECUTE IMMEDIATE 'DROP TABLE CHNK_IDN_OATH_AUTHRIZATN_CODE';
      COMMIT;
      END if;

      EXECUTE IMMEDIATE 'CREATE TABLE CHNK_IDN_OATH_AUTHRIZATN_CODE (ROW_ID rowid,CONSTRAINT CHNK_IDN_OATH_AUTHRIZN_PRI PRIMARY KEY (ROW_ID)) NOLOGGING';
      COMMIT;

      EXECUTE IMMEDIATE 'INSERT /*+ APPEND */ INTO CHNK_IDN_OATH_AUTHRIZATN_CODE (ROW_ID) SELECT rowid FROM IDN_OAUTH2_AUTHORIZATION_CODE WHERE rownum <= :chkSize AND CODE_ID IN
      (SELECT CODE_ID FROM IDN_OAUTH2_AUTHORIZATION_CODE code WHERE NOT EXISTS (SELECT * FROM IDN_OAUTH2_ACCESS_TOKEN tok where tok.TOKEN_ID = code.TOKEN_ID))
      AND (VALIDITY_PERIOD < :mxValdPrid AND :dTL > (TIME_CREATED + NUMTODSINTERVAL( VALIDITY_PERIOD / 60000, ''MINUTE'' )))' using chunkSize,maxValidityPeriod,deleteTimeLimit ;

      chunkCount:=  sql%Rowcount;
      COMMIT;

      EXIT WHEN chunkCount = 0 ;
      IF (enableLog AND logLevel IN ('DEBUG','TRACE'))
      THEN
      EXECUTE IMMEDIATE 'INSERT INTO LOG_WSO2_TOKEN_CLEANUP_SP (TIMESTAMP,LOG) VALUES (TO_CHAR( SYSTIMESTAMP, ''DD.MM.YYYY HH24:MI:SS:FF4''),''CHUNK TABLE CHNK_IDN_OATH_AUTHRIZATN_CODE CREATED WITH : '||chunkCount||''')';
      COMMIT;
      END IF;

      IF (enableAudit)
      THEN
      EXECUTE IMMEDIATE 'INSERT INTO ADT_OAUTH2_AUTHORIZATION_CODE SELECT CODE.* FROM IDN_OAUTH2_AUTHORIZATION_CODE CODE , CHNK_IDN_OATH_AUTHRIZATN_CODE CHK WHERE CODE.ROWID=CHK.ROW_ID';
      COMMIT;
      END IF;

      LOOP
          SELECT COUNT(*) INTO ROWCOUNT from ALL_TABLES where OWNER = CURRENT_SCHEMA AND table_name = upper('BATCH_IDN_OATH2_AUTHRIZATN_CDE');
          IF (ROWCOUNT = 1) then
          EXECUTE IMMEDIATE 'DROP TABLE BATCH_IDN_OATH2_AUTHRIZATN_CDE';
          COMMIT;
          END if;

          EXECUTE IMMEDIATE 'CREATE TABLE BATCH_IDN_OATH2_AUTHRIZATN_CDE (ROW_ID rowid,CONSTRAINT BATCH_IDN_OATH_AUTHRIZN_PRI PRIMARY KEY (ROW_ID)) NOLOGGING';
          COMMIT;

          EXECUTE IMMEDIATE 'INSERT /*+ APPEND */ INTO BATCH_IDN_OATH2_AUTHRIZATN_CDE (ROW_ID) SELECT ROW_ID FROM CHNK_IDN_OATH_AUTHRIZATN_CODE WHERE rownum <= '||batchSize||'';
          batchCount:= sql%rowcount;
          COMMIT;

          EXIT WHEN batchCount = 0 ;

          IF (enableLog AND logLevel IN ('TRACE'))
          THEN
          EXECUTE IMMEDIATE 'INSERT INTO LOG_WSO2_TOKEN_CLEANUP_SP (TIMESTAMP,LOG) VALUES (TO_CHAR( SYSTIMESTAMP, ''DD.MM.YYYY HH24:MI:SS:FF4''),''BATCH DELETE START ON TABLE IDN_OAUTH2_AUTHORIZATION_CODE WITH : '||batchCount||''')';
          COMMIT;
          END IF;

          IF ((batchCount > 0))
          THEN
          EXECUTE IMMEDIATE 'DELETE FROM IDN_OAUTH2_AUTHORIZATION_CODE where rowid in (select ROW_ID from BATCH_IDN_OATH2_AUTHRIZATN_CDE)';
          deleteCount:= sql%rowcount;
          COMMIT;
          END IF;
          IF (enableLog)
          THEN
          EXECUTE IMMEDIATE  'INSERT INTO LOG_WSO2_TOKEN_CLEANUP_SP (TIMESTAMP,LOG) VALUES (TO_CHAR( SYSTIMESTAMP, ''DD.MM.YYYY HH24:MI:SS:FF4''),''BATCH DELETE FINISHED ON IDN_OAUTH2_AUTHORIZATION_CODE WITH : '||deleteCount||''')';
          COMMIT;
          END IF;

          EXECUTE IMMEDIATE 'DELETE CHNK_IDN_OATH_AUTHRIZATN_CODE WHERE ROW_ID in (select ROW_ID from BATCH_IDN_OATH2_AUTHRIZATN_CDE)';
          COMMIT;
          IF (enableLog AND logLevel IN ('DEBUG','TRACE'))
          THEN
          EXECUTE IMMEDIATE 'INSERT INTO LOG_WSO2_TOKEN_CLEANUP_SP (TIMESTAMP,LOG) VALUES (TO_CHAR( SYSTIMESTAMP, ''DD.MM.YYYY HH24:MI:SS:FF4''),''DELETED BATCH ON  CHNK_IDN_OATH_AUTHRIZATN_CODE !'')';
          COMMIT;
          END IF;

          IF ((deleteCount > 0))
          THEN
          IF (enableLog AND logLevel IN ('DEBUG','TRACE'))
          THEN
          EXECUTE IMMEDIATE 'INSERT INTO LOG_WSO2_TOKEN_CLEANUP_SP (TIMESTAMP,LOG) VALUES (TO_CHAR( SYSTIMESTAMP, ''DD.MM.YYYY HH24:MI:SS:FF4''),''SLEEPING ...'')';
          COMMIT;
          END IF;
          DBMS_LOCK.SLEEP(sleepTime);
          END IF;
      END LOOP;
END LOOP;

--
IF (enableLog)
THEN
  EXECUTE IMMEDIATE 'INSERT INTO LOG_WSO2_TOKEN_CLEANUP_SP (TIMESTAMP,LOG) VALUES (TO_CHAR( SYSTIMESTAMP, ''DD.MM.YYYY HH24:MI:SS:FF4''),''BATCH DELETE ON IDN_OAUTH2_AUTHORIZATION_CODE COMPLETED .... !'')';
  EXECUTE IMMEDIATE 'INSERT INTO LOG_WSO2_TOKEN_CLEANUP_SP (TIMESTAMP,LOG) VALUES (TO_CHAR( SYSTIMESTAMP, ''DD.MM.YYYY HH24:MI:SS:FF4''),'' '')';
  COMMIT;
END IF;

IF (enableLog AND logLevel IN ('DEBUG','TRACE'))
THEN
    SELECT COUNT(1) INTO ROWCOUNT FROM IDN_OAUTH2_ACCESS_TOKEN;
    EXECUTE IMMEDIATE 'INSERT INTO LOG_WSO2_TOKEN_CLEANUP_SP (TIMESTAMP,LOG) VALUES (TO_CHAR( SYSTIMESTAMP, ''DD.MM.YYYY HH24:MI:SS:FF4''),''TOTAL TOKENS ON IDN_OAUTH2_ACCESS_TOKEN TABLE AFTER DELETE :'||ROWCOUNT||''')';
    COMMIT;

    SELECT COUNT(1) INTO ROWCOUNT FROM IDN_OAUTH2_AUTHORIZATION_CODE;
    EXECUTE IMMEDIATE 'INSERT INTO LOG_WSO2_TOKEN_CLEANUP_SP (TIMESTAMP,LOG) VALUES (TO_CHAR( SYSTIMESTAMP, ''DD.MM.YYYY HH24:MI:SS:FF4''),''TOTAL TOKENS ON IDN_OAUTH2_AUTHORIZATION_CODE TABLE AFTER DELETE :'||ROWCOUNT||''')';
    COMMIT;

    EXECUTE IMMEDIATE 'INSERT INTO LOG_WSO2_TOKEN_CLEANUP_SP (TIMESTAMP,LOG) VALUES (TO_CHAR( SYSTIMESTAMP, ''DD.MM.YYYY HH24:MI:SS:FF4''),'' '')';
    COMMIT;
END IF;


-- ------------------------------------------------------
-- REBUILDING INDEXES
-- ------------------------------------------------------

IF(enableRebuildIndexes)
THEN
      FOR cursorTable IN backupTablesCursor
      LOOP
            FOR INDEX_ENTRY IN (SELECT INDEX_NAME FROM ALL_INDEXES WHERE  TABLE_NAME=''||cursorTable.TABLE_NAME||'' AND INDEX_TYPE='NORMAL' AND OWNER = CURRENT_SCHEMA)
            LOOP
                IF (enableLog AND logLevel IN ('DEBUG','TRACE'))
                THEN
                EXECUTE IMMEDIATE 'INSERT INTO LOG_WSO2_TOKEN_CLEANUP_SP (TIMESTAMP,LOG) VALUES (TO_CHAR( SYSTIMESTAMP, ''DD.MM.YYYY HH24:MI:SS:FF4''),''REBUILDING INDEXES ON '||cursorTable.TABLE_NAME||' TABLE : '||INDEX_ENTRY.INDEX_NAME||''')';
                COMMIT;
                END IF;
                EXECUTE IMMEDIATE 'ALTER INDEX ' || INDEX_ENTRY.INDEX_NAME || ' REBUILD';
                COMMIT;
            END LOOP;
      END LOOP;

      IF (enableLog AND logLevel IN ('DEBUG','TRACE'))
      THEN
      EXECUTE IMMEDIATE 'INSERT INTO LOG_WSO2_TOKEN_CLEANUP_SP (TIMESTAMP,LOG) VALUES (TO_CHAR( SYSTIMESTAMP, ''DD.MM.YYYY HH24:MI:SS:FF4''),'' '')';
      END IF;
      COMMIT;
END IF;


-- ------------------------------------------------------
-- STATS GATHERING FOR OPTIMUM PERFOMANCE
-- ------------------------------------------------------

IF(enableStsGthrn)
THEN
    IF (enableLog AND logLevel IN ('DEBUG','TRACE'))
    THEN
    EXECUTE IMMEDIATE 'INSERT INTO LOG_WSO2_TOKEN_CLEANUP_SP (TIMESTAMP,LOG) VALUES (TO_CHAR( SYSTIMESTAMP, ''DD.MM.YYYY HH24:MI:SS:FF4''),''SCHEMA LEVEL STATS GATHERING JOB STARTED.'')';
    COMMIT;
    END IF;

    BEGIN
    dbms_stats.gather_schema_stats(CURRENT_SCHEMA,DBMS_STATS.AUTO_SAMPLE_SIZE);
    END;

    IF (enableLog AND logLevel IN ('DEBUG','TRACE'))
    THEN
    EXECUTE IMMEDIATE 'INSERT INTO LOG_WSO2_TOKEN_CLEANUP_SP (TIMESTAMP,LOG) VALUES (TO_CHAR( SYSTIMESTAMP, ''DD.MM.YYYY HH24:MI:SS:FF4''),''SCHEMA LEVEL STATS GATHERING JOB COMPLETED.'')';
    EXECUTE IMMEDIATE 'INSERT INTO LOG_WSO2_TOKEN_CLEANUP_SP (TIMESTAMP,LOG) VALUES (TO_CHAR( SYSTIMESTAMP, ''DD.MM.YYYY HH24:MI:SS:FF4''),'' '')';
    COMMIT;
    END IF;
END IF;

IF (enableLog AND logLevel IN ('DEBUG','TRACE'))
THEN
EXECUTE IMMEDIATE 'INSERT INTO LOG_WSO2_TOKEN_CLEANUP_SP (TIMESTAMP,LOG) VALUES (TO_CHAR( SYSTIMESTAMP, ''DD.MM.YYYY HH24:MI:SS:FF4''),''TOKEN_CLEANUP_SP COMPLETED .... !'')';
COMMIT;
END IF;

END;
