CREATE OR REPLACE FUNCTION executetransaction(p_transid BIGINT)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    v_fromid BIGINT;
    v_toid   BIGINT;
    v_amount NUMERIC(18,4);

    v_transserviceid SMALLINT;
    v_transtype SMALLINT;
    v_transisexecuted BOOLEAN;

    v_fromsubscriptiontype SMALLINT;
    v_tosubscriptiontype SMALLINT;

    v_fromserviceid SMALLINT;
    v_toserviceid SMALLINT;

    v_fromfees NUMERIC(18,4) := 0;
    v_tofees   NUMERIC(18,4) := 0;

    v_fromoldbalance NUMERIC(18,4);
    v_tooldbalance   NUMERIC(18,4);

    v_fromnewbalance NUMERIC(18,4);
    v_tonewbalance   NUMERIC(18,4);

    v_tomaxlimit NUMERIC(18,4);
    v_tominlimit NUMERIC(18,4);
    v_fromminlimit NUMERIC(18,4);
    v_frommaxlimit NUMERIC(18,4);

    v_fromexpirationdate TIMESTAMPTZ;
    v_toexpirationdate   TIMESTAMPTZ;

    v_fromlastupdate TIMESTAMPTZ;
    v_tolastupdate   TIMESTAMPTZ;

    v_executionguid UUID := gen_random_uuid();

    v_fromstatus SMALLINT;
    v_tostatus   SMALLINT;

    v_fromcurrencyid SMALLINT;
    v_tocurrencyid   SMALLINT;

    v_requiresreservation BOOLEAN;

    v_fromreservedbalance NUMERIC(18,4);
    v_fromnewreservedbalance NUMERIC(18,4);

    v_utcnow TIMESTAMPTZ := timezone('utc', now());
    v_rowcount INT;

    -- error logging
    v_errmsg TEXT;
    v_errnum INT;
BEGIN
    -- 1) Input validation
    IF p_transid IS NULL THEN
        RAISE EXCEPTION '50000: Invalid Transaction ID: NULL';
    END IF;

    -- We'll use temp tables similar to SQL Server table variables
    DROP TABLE IF EXISTS fee_calculation;
    DROP TABLE IF EXISTS invalid_fee_accounts;
    DROP TABLE IF EXISTS fee_account_balances;
    DROP TABLE IF EXISTS log_entries;

    CREATE TEMP TABLE fee_calculation (
        feeid       BIGINT,
        feesaccount BIGINT,
        fromfees    NUMERIC(18,4),
        tofees      NUMERIC(18,4),
        sequenceid  INT
    ) ON COMMIT DROP;

    CREATE TEMP TABLE invalid_fee_accounts (
        feeid       BIGINT,
        feesaccount BIGINT,
        errortype   TEXT
    ) ON COMMIT DROP;

    CREATE TEMP TABLE fee_account_balances (
        feesaccount BIGINT PRIMARY KEY,
        oldbalance  NUMERIC(18,4),
        lastupdate  TIMESTAMPTZ
    ) ON COMMIT DROP;

    CREATE TEMP TABLE log_entries (
        transid        BIGINT,
        accountid      BIGINT,
        amount         NUMERIC(18,4),
        executedate    TIMESTAMPTZ,
        executionguid  UUID,
        balancebefore  NUMERIC(18,4),
        balanceafter   NUMERIC(18,4),
        note           TEXT,
        processingorder INT
    ) ON COMMIT DROP;

    -- 3.1) Fetch transaction details
    SELECT
        tl.fromid,
        tl.toid,
        tl.amount,
        tl.serviceid,
        tl.transtype,
        tl.isexecuted,
        stt.requiresreservation
    INTO
        v_fromid,
        v_toid,
        v_amount,
        v_transserviceid,
        v_transtype,
        v_transisexecuted,
        v_requiresreservation
    FROM translog tl
    JOIN servicestranstypes stt
      ON stt.typeid = tl.transtype
     AND stt.serviceid = tl.serviceid
    WHERE tl.transid = p_transid;

    IF NOT FOUND THEN
        RAISE EXCEPTION '50001: No transaction found with the given ID: %', p_transid;
    END IF;

    IF v_transisexecuted THEN
        RAISE EXCEPTION '50002: The transaction % was already executed successfully.', p_transid;
    END IF;

    IF v_fromid = v_toid THEN
        RAISE EXCEPTION '50003: Cannot transfer from account % to itself.', v_fromid;
    END IF;

    -- 3.3) Fetch sender
    SELECT
        subscriptiontype,
        balance,
        reservedbalance,
        expirationdate,
        serviceid,
        minlimit,
        maxlimit,
        lastupdate,
        status,
        currencyid
    INTO
        v_fromsubscriptiontype,
        v_fromoldbalance,
        v_fromreservedbalance,
        v_fromexpirationdate,
        v_fromserviceid,
        v_fromminlimit,
        v_frommaxlimit,
        v_fromlastupdate,
        v_fromstatus,
        v_fromcurrencyid
    FROM accounts
    WHERE accountid = v_fromid;

    IF NOT FOUND THEN
        RAISE EXCEPTION '50004: The sender account % does not exist.', v_fromid;
    END IF;

    IF v_fromstatus <> 1 THEN
        RAISE EXCEPTION '50005: The sender account % is not active.', v_fromid;
    END IF;

    -- Receiver
    SELECT
        subscriptiontype,
        balance,
        expirationdate,
        maxlimit,
        minlimit,
        serviceid,
        lastupdate,
        status,
        currencyid
    INTO
        v_tosubscriptiontype,
        v_tooldbalance,
        v_toexpirationdate,
        v_tomaxlimit,
        v_tominlimit,
        v_toserviceid,
        v_tolastupdate,
        v_tostatus,
        v_tocurrencyid
    FROM accounts
    WHERE accountid = v_toid;

    IF NOT FOUND THEN
        RAISE EXCEPTION '50006: The receiver account % does not exist.', v_toid;
    END IF;

    IF v_tostatus <> 1 THEN
        RAISE EXCEPTION '50007: The receiver account % is not active.', v_toid;
    END IF;

    -- 3.4) Validate service/currency/expiry
    IF v_fromserviceid <> v_transserviceid OR v_toserviceid <> v_transserviceid THEN
        RAISE EXCEPTION '50008: The service ids do not match. FromServiceID: %, TransServiceID: %, ToServiceID: %.',
            v_fromserviceid, v_transserviceid, v_toserviceid;
    END IF;

    IF v_fromcurrencyid <> v_tocurrencyid THEN
        RAISE EXCEPTION '50009: The currencies do not match. FromCurrencyID: %, ToCurrencyID: %.',
            v_fromcurrencyid, v_tocurrencyid;
    END IF;

    IF v_fromexpirationdate < v_utcnow THEN
        RAISE EXCEPTION '50010: The sender''s account is expired. Expiry Date: %, Current Date: %.',
            v_fromexpirationdate, v_utcnow;
    END IF;

    IF v_toexpirationdate < v_utcnow THEN
        RAISE EXCEPTION '50011: The receiver''s account is expired. Expiry Date: %, Current Date: %.',
            v_toexpirationdate, v_utcnow;
    END IF;

    -- 3.5) Fee calculation into temp table
    INSERT INTO fee_calculation (feeid, feesaccount, fromfees, tofees, sequenceid)
    SELECT
        f.feeid,
        f.feesaccount,
        SUM(
            CASE
                WHEN v_amount >= f.applyinglimit AND v_amount <= f.exemptionlimit
                THEN COALESCE(f.fromfixedfees,0) + (COALESCE(f.frompercentfees,0) * v_amount / 100)
                ELSE 0
            END
        ) AS fromfees,
        SUM(
            CASE
                WHEN v_amount >= f.applyinglimit AND v_amount <= f.exemptionlimit
                THEN COALESCE(f.tofixedfees,0) + (COALESCE(f.topercentfees,0) * v_amount / 100)
                ELSE 0
            END
        ) AS tofees,
        f.sequenceid
    FROM fees f
    WHERE f.serviceid = v_transserviceid
      AND f.servicetranstypeid = v_transtype
      AND f.fromsubscriptiontypeid = v_fromsubscriptiontype
      AND f.tosubscriptiontypeid = v_tosubscriptiontype
    GROUP BY f.feeid, f.feesaccount, f.sequenceid;

    -- Validate fee accounts
    INSERT INTO invalid_fee_accounts (feeid, feesaccount, errortype)
    SELECT
        fc.feeid,
        fc.feesaccount,
        CASE
            WHEN a.accountid IS NULL THEN 'Non-existent'
            WHEN a.status <> 1 THEN 'Inactive'
            WHEN a.expirationdate < v_utcnow THEN 'Expired'
            WHEN a.currencyid <> v_fromcurrencyid THEN 'Currency Mismatch'
            ELSE NULL
        END AS errortype
    FROM fee_calculation fc
    LEFT JOIN accounts a ON a.accountid = fc.feesaccount
    WHERE fc.feesaccount IS NOT NULL
      AND (
            a.accountid IS NULL
         OR a.status <> 1
         OR a.expirationdate < v_utcnow
         OR a.currencyid <> v_fromcurrencyid
      );

    IF EXISTS (SELECT 1 FROM invalid_fee_accounts) THEN
        RAISE EXCEPTION '50012: The following fee accounts have issues: %',
            (SELECT string_agg(
                format('FeeID: %s, FeesAccount: %s, Error: %s', feeid, feesaccount, errortype),
                E'\n'
            ) FROM invalid_fee_accounts);
    END IF;

    -- Total fees
    SELECT
        COALESCE(SUM(fromfees),0),
        COALESCE(SUM(tofees),0)
    INTO v_fromfees, v_tofees
    FROM fee_calculation;

    -- Fee account balances snapshot
    INSERT INTO fee_account_balances (feesaccount, oldbalance, lastupdate)
    SELECT DISTINCT
        fc.feesaccount,
        a.balance,
        a.lastupdate
    FROM fee_calculation fc
    JOIN accounts a ON a.accountid = fc.feesaccount
    WHERE fc.feesaccount IS NOT NULL;

    -- Update fee accounts with concurrency control
    WITH total_fees_per_account AS (
        SELECT
            feesaccount,
            SUM(fromfees) AS totalfromfees,
            SUM(tofees)   AS totaltofees
        FROM fee_calculation
        WHERE feesaccount IS NOT NULL
        GROUP BY feesaccount
    )
    UPDATE accounts a
    SET
        balance = a.balance + tf.totalfromfees + tf.totaltofees,
        lastupdate = v_utcnow
    FROM total_fees_per_account tf
    JOIN fee_account_balances fab ON fab.feesaccount = tf.feesaccount
    WHERE a.accountid = tf.feesaccount
      AND a.lastupdate = fab.lastupdate;

    GET DIAGNOSTICS v_rowcount = ROW_COUNT;
    IF v_rowcount < (SELECT COUNT(*) FROM fee_account_balances) THEN
        RAISE EXCEPTION '50013: One or more fee accounts were changed during execution.';
    END IF;

    -- 3.6) Balance updates
    v_fromnewbalance := v_fromoldbalance - v_amount - v_fromfees;
    v_tonewbalance   := v_tooldbalance + v_amount - v_tofees;

    IF v_fromnewbalance < v_fromminlimit OR v_fromnewbalance > v_frommaxlimit THEN
        RAISE EXCEPTION '50014: Transaction will make sender''s balance outside allowed limits. FromMinLimit: %, FromMaxLimit: %, FromNewBalance: %',
            v_fromminlimit, v_frommaxlimit, v_fromnewbalance;
    END IF;

    IF v_tonewbalance < v_tominlimit OR v_tonewbalance > v_tomaxlimit THEN
        RAISE EXCEPTION '50015: Transaction will make receiver''s balance outside allowed limits. ToMinLimit: %, ToMaxLimit: %, ToNewBalance: %',
            v_tominlimit, v_tomaxlimit, v_tonewbalance;
    END IF;

    IF v_requiresreservation THEN
        IF v_fromreservedbalance < (v_amount + v_fromfees) THEN
            RAISE EXCEPTION '50020: Insufficient reserved balance. Required: %, Reserved: %',
                (v_amount + v_fromfees), v_fromreservedbalance;
        END IF;

        v_fromnewreservedbalance := v_fromreservedbalance - (v_amount + v_fromfees);
    END IF;

    -- 3.7) Logging
    -- Main transaction entries
    INSERT INTO log_entries (transid, accountid, amount, executedate, executionguid, balancebefore, balanceafter, note, processingorder)
    VALUES
        (p_transid, v_fromid, -v_amount, v_utcnow, v_executionguid, v_fromoldbalance, v_fromoldbalance - v_amount, 'Transaction Amount Debit', 1),
        (p_transid, v_toid,    v_amount, v_utcnow, v_executionguid, v_tooldbalance, v_tooldbalance + v_amount, 'Transaction Amount Credit', 2);

    -- Fee entries in sequence order (same math as your T-SQL)
    INSERT INTO log_entries (transid, accountid, amount, executedate, executionguid, balancebefore, balanceafter, note, processingorder)
    SELECT
        p_transid,
        x.accountid,
        x.amount,
        v_utcnow,
        v_executionguid,
        x.balancebefore,
        x.balanceafter,
        x.note,
        x.processingorder
    FROM (
        -- Sender fee debits
        SELECT
            v_fromid AS accountid,
            -fc.fromfees AS amount,
            (v_fromoldbalance - v_amount) - (
                SELECT COALESCE(SUM(fc2.fromfees),0) FROM fee_calculation fc2 WHERE fc2.sequenceid < fc.sequenceid
            ) AS balancebefore,
            (v_fromoldbalance - v_amount) - (
                SELECT COALESCE(SUM(fc2.fromfees),0) FROM fee_calculation fc2 WHERE fc2.sequenceid <= fc.sequenceid
            ) AS balanceafter,
            format('Sender Fee Debit - FeeID: %s - Sequence: %s', fc.feeid, fc.sequenceid) AS note,
            (fc.sequenceid * 3) AS processingorder
        FROM fee_calculation fc
        WHERE fc.fromfees > 0

        UNION ALL

        -- Receiver fee debits
        SELECT
            v_toid AS accountid,
            -fc.tofees AS amount,
            (v_tooldbalance + v_amount) - (
                SELECT COALESCE(SUM(fc2.tofees),0) FROM fee_calculation fc2 WHERE fc2.sequenceid < fc.sequenceid
            ) AS balancebefore,
            (v_tooldbalance + v_amount) - (
                SELECT COALESCE(SUM(fc2.tofees),0) FROM fee_calculation fc2 WHERE fc2.sequenceid <= fc.sequenceid
            ) AS balanceafter,
            format('Receiver Fee Debit - FeeID: %s - Sequence: %s', fc.feeid, fc.sequenceid) AS note,
            (fc.sequenceid * 3) + 1 AS processingorder
        FROM fee_calculation fc
        WHERE fc.tofees > 0

        UNION ALL

        -- Fee account credits
        SELECT
            fc.feesaccount AS accountid,
            (fc.fromfees + fc.tofees) AS amount,
            fab.oldbalance + (
                SELECT COALESCE(SUM(fc2.fromfees + fc2.tofees),0)
                FROM fee_calculation fc2
                WHERE fc2.feesaccount = fc.feesaccount
                  AND fc2.sequenceid < fc.sequenceid
            ) AS balancebefore,
            fab.oldbalance + (
                SELECT COALESCE(SUM(fc2.fromfees + fc2.tofees),0)
                FROM fee_calculation fc2
                WHERE fc2.feesaccount = fc.feesaccount
                  AND fc2.sequenceid <= fc.sequenceid
            ) AS balanceafter,
            (
                CASE
                    WHEN fc.fromfees > 0 AND fc.tofees > 0 THEN 'Combined'
                    WHEN fc.fromfees > 0 THEN 'Sender'
                    ELSE 'Receiver'
                END
                || format(' Fee Credit - FeeID: %s - Sequence: %s', fc.feeid, fc.sequenceid)
            ) AS note,
            (fc.sequenceid * 3) + 2 AS processingorder
        FROM fee_calculation fc
        JOIN fee_account_balances fab ON fab.feesaccount = fc.feesaccount
        WHERE fc.feesaccount IS NOT NULL
          AND (fc.fromfees > 0 OR fc.tofees > 0)
    ) x;

    -- Persist ordered logs
    INSERT INTO changebalancelog (
        transid, accountid, amount, executedate, executionguid,
        balancebefore, balanceafter, note
    )
    SELECT
        transid, accountid, amount, executedate, executionguid,
        balancebefore, balanceafter, note
    FROM log_entries
    ORDER BY processingorder;

    -- 3.8) Execute transaction (final updates with concurrency checks)
    IF v_requiresreservation THEN
        UPDATE accounts
        SET
            balance = v_fromnewbalance,
            reservedbalance = v_fromnewreservedbalance,
            lastupdate = v_utcnow
        WHERE accountid = v_fromid
          AND lastupdate = v_fromlastupdate
          AND balance = v_fromoldbalance
          AND reservedbalance = v_fromreservedbalance;
    ELSE
        UPDATE accounts
        SET
            balance = v_fromnewbalance,
            lastupdate = v_utcnow
        WHERE accountid = v_fromid
          AND lastupdate = v_fromlastupdate
          AND balance = v_fromoldbalance;
    END IF;

    GET DIAGNOSTICS v_rowcount = ROW_COUNT;
    IF v_rowcount = 0 THEN
        RAISE EXCEPTION '50016: The sender''s account was changed during execution';
    END IF;

    UPDATE accounts
    SET
        balance = v_tonewbalance,
        lastupdate = v_utcnow
    WHERE accountid = v_toid
      AND lastupdate = v_tolastupdate
      AND balance = v_tooldbalance;

    GET DIAGNOSTICS v_rowcount = ROW_COUNT;
    IF v_rowcount = 0 THEN
        RAISE EXCEPTION '50017: The receiver''s account was changed during execution';
    END IF;

    UPDATE translog
    SET
        isexecuted = TRUE,
        executiondate = v_utcnow,
        isclosed = TRUE,
        closingdate = v_utcnow,
        closedby = current_user
    WHERE transid = p_transid;

    -- 4) Success log
    INSERT INTO transexecutionlog (transid, executiondate, issuccessful, message, errornumber, errorstate, serviceid)
    VALUES (p_transid, v_utcnow, TRUE, 'Transaction Executed Successfully', NULL, NULL, v_transserviceid);

    RETURN 'success';

EXCEPTION
    WHEN OTHERS THEN
        v_errmsg := SQLERRM;

        -- Try to extract your numeric error code from the message prefix "50014: ..."
        v_errnum := NULL;
        IF v_errmsg ~ '^[0-9]{5}:' THEN
            v_errnum := substring(v_errmsg from '^[0-9]{5}')::int;
        END IF;

        INSERT INTO transexecutionlog (transid, executiondate, issuccessful, message, errornumber, errorstate, serviceid)
        VALUES (COALESCE(p_transid, 0), timezone('utc', now()), FALSE, v_errmsg, v_errnum, NULL, v_transserviceid);

        RAISE;
END;
$$;