-- Quick test: create + execute a transaction, then print logs
\set ON_ERROR_STOP on

BEGIN;

DROP TABLE IF EXISTS _demo_trans;
CREATE TEMP TABLE _demo_trans (transid BIGINT);

INSERT INTO _demo_trans (transid)
SELECT (createtransaction(
    1001::bigint,
    2002::bigint,
    100.0000::numeric(18,4),
    1::smallint,
    1::smallint
)).transid;

SELECT transid AS created_transid FROM _demo_trans;

SELECT executetransaction(transid) AS execution_result
FROM _demo_trans;

\echo 'ChangeBalanceLog'
SELECT *
FROM changebalancelog
WHERE transid IN (SELECT transid FROM _demo_trans)
ORDER BY logid;

\echo 'TransExecutionLog'
SELECT *
FROM transexecutionlog
WHERE transid IN (SELECT transid FROM _demo_trans)
ORDER BY executionid;

COMMIT;
