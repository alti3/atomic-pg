CREATE OR REPLACE FUNCTION execute_transaction(p_transid BIGINT)
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

    v_fee_snapshot JSONB := '[]'::jsonb;
    v_invalid_fee_accounts TEXT;

    v_utcnow TIMESTAMPTZ := timezone('utc', now());
    v_rowcount INT;
    v_expected_fee_updates INT := 0;
    v_fromupdated BOOLEAN := FALSE;
    v_toupdated BOOLEAN := FALSE;

    -- error logging
    v_errmsg TEXT;
    v_errnum INT;
BEGIN
    -- 1) Input validation
    IF p_transid IS NULL THEN
        RAISE EXCEPTION '50000: Invalid Transaction ID: NULL';
    END IF;

    -- 2) Read-only validation phase
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
    FROM transaction_log tl
    JOIN service_transaction_types stt
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

    -- Materialize fee rows once in the read phase so later updates/logs reuse the same snapshot.
    WITH fee_calculation AS MATERIALIZED (
        SELECT
            f.feeid,
            f.feesaccount,
            CASE
                WHEN v_amount >= f.applyinglimit AND v_amount <= f.exemptionlimit
                THEN COALESCE(f.fromfixedfees, 0) + (COALESCE(f.frompercentfees, 0) * v_amount / 100)
                ELSE 0
            END AS fromfees,
            CASE
                WHEN v_amount >= f.applyinglimit AND v_amount <= f.exemptionlimit
                THEN COALESCE(f.tofixedfees, 0) + (COALESCE(f.topercentfees, 0) * v_amount / 100)
                ELSE 0
            END AS tofees,
            f.sequenceid
        FROM fees f
        WHERE f.serviceid = v_transserviceid
          AND f.servicetranstypeid = v_transtype
          AND f.fromsubscriptiontypeid = v_fromsubscriptiontype
          AND f.tosubscriptiontypeid = v_tosubscriptiontype
    ),
    fee_accounts AS MATERIALIZED (
        SELECT DISTINCT
            fc.feesaccount,
            a.accountid,
            a.balance AS oldbalance,
            a.lastupdate,
            a.status,
            a.expirationdate,
            a.currencyid
        FROM fee_calculation fc
        LEFT JOIN accounts a
          ON a.accountid = fc.feesaccount
        WHERE fc.feesaccount IS NOT NULL
    ),
    invalid_fee_accounts AS (
        SELECT
            fc.feeid,
            fc.feesaccount,
            CASE
                WHEN fa.accountid IS NULL THEN 'Non-existent'
                WHEN fa.status <> 1 THEN 'Inactive'
                WHEN fa.expirationdate < v_utcnow THEN 'Expired'
                WHEN fa.currencyid <> v_fromcurrencyid THEN 'Currency Mismatch'
                ELSE NULL
            END AS errortype
        FROM fee_calculation fc
        LEFT JOIN fee_accounts fa
          ON fa.feesaccount = fc.feesaccount
        WHERE fc.feesaccount IS NOT NULL
          AND (
                fa.accountid IS NULL
             OR fa.status <> 1
             OR fa.expirationdate < v_utcnow
             OR fa.currencyid <> v_fromcurrencyid
          )
    ),
    fee_totals AS (
        SELECT
            COALESCE(SUM(fromfees), 0) AS fromfees,
            COALESCE(SUM(tofees), 0) AS tofees
        FROM fee_calculation
    ),
    fee_snapshot AS (
        SELECT jsonb_agg(
            jsonb_build_object(
                'feeid', fc.feeid,
                'feesaccount', fc.feesaccount,
                'fromfees', fc.fromfees,
                'tofees', fc.tofees,
                'sequenceid', fc.sequenceid,
                'feeaccount_oldbalance', fa.oldbalance,
                'feeaccount_lastupdate', fa.lastupdate
            )
            ORDER BY fc.sequenceid, fc.feeid
        ) AS fee_rows
        FROM fee_calculation fc
        LEFT JOIN fee_accounts fa
          ON fa.feesaccount = fc.feesaccount
    )
    SELECT
        ft.fromfees,
        ft.tofees,
        COALESCE(fs.fee_rows, '[]'::jsonb),
        (
            SELECT string_agg(
                format('FeeID: %s, FeesAccount: %s, Error: %s', feeid, feesaccount, errortype),
                E'\n'
            )
            FROM invalid_fee_accounts
        )
    INTO
        v_fromfees,
        v_tofees,
        v_fee_snapshot,
        v_invalid_fee_accounts
    FROM fee_totals ft
    CROSS JOIN fee_snapshot fs;

    IF v_invalid_fee_accounts IS NOT NULL THEN
        RAISE EXCEPTION '50012: The following fee accounts have issues: %', v_invalid_fee_accounts;
    END IF;

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

    -- 3) Write phase: start touching mutable rows only after all validation passes.
    WITH updated_accounts AS (
        UPDATE accounts a
        SET
            balance = CASE
                WHEN a.accountid = v_fromid THEN v_fromnewbalance
                WHEN a.accountid = v_toid THEN v_tonewbalance
                ELSE a.balance
            END,
            reservedbalance = CASE
                WHEN v_requiresreservation AND a.accountid = v_fromid THEN v_fromnewreservedbalance
                ELSE a.reservedbalance
            END,
            lastupdate = v_utcnow
        WHERE (
                a.accountid = v_fromid
            AND a.lastupdate = v_fromlastupdate
            AND a.balance = v_fromoldbalance
            AND (
                    NOT v_requiresreservation
                 OR a.reservedbalance = v_fromreservedbalance
                )
        )
           OR (
                a.accountid = v_toid
            AND a.lastupdate = v_tolastupdate
            AND a.balance = v_tooldbalance
        )
        RETURNING a.accountid
    )
    SELECT
        COALESCE(BOOL_OR(accountid = v_fromid), FALSE),
        COALESCE(BOOL_OR(accountid = v_toid), FALSE)
    INTO
        v_fromupdated,
        v_toupdated
    FROM updated_accounts;

    IF NOT v_fromupdated THEN
        RAISE EXCEPTION '50016: The sender''s account was changed during execution';
    END IF;

    IF NOT v_toupdated THEN
        RAISE EXCEPTION '50017: The receiver''s account was changed during execution';
    END IF;

    WITH fee_rows AS (
        SELECT *
        FROM jsonb_to_recordset(v_fee_snapshot) AS fc(
            feeid BIGINT,
            feesaccount BIGINT,
            fromfees NUMERIC(18,4),
            tofees NUMERIC(18,4),
            sequenceid INT,
            feeaccount_oldbalance NUMERIC(18,4),
            feeaccount_lastupdate TIMESTAMPTZ
        )
    ),
    fee_totals AS (
        SELECT
            feesaccount,
            MAX(feeaccount_oldbalance) AS oldbalance,
            MAX(feeaccount_lastupdate) AS oldlastupdate,
            SUM(fromfees + tofees) AS totalfees
        FROM fee_rows
        WHERE feesaccount IS NOT NULL
          AND (fromfees > 0 OR tofees > 0)
        GROUP BY feesaccount
    ),
    fee_updates AS (
        UPDATE accounts a
        SET
            balance = a.balance + ft.totalfees,
            lastupdate = v_utcnow
        FROM fee_totals ft
        WHERE a.accountid = ft.feesaccount
          AND a.lastupdate = ft.oldlastupdate
          AND a.balance = ft.oldbalance
        RETURNING 1
    )
    SELECT
        (SELECT COUNT(*) FROM fee_totals),
        (SELECT COUNT(*) FROM fee_updates)
    INTO
        v_expected_fee_updates,
        v_rowcount;

    IF v_rowcount < v_expected_fee_updates THEN
        RAISE EXCEPTION '50013: One or more fee accounts were changed during execution.';
    END IF;

    WITH fee_rows AS (
        SELECT *
        FROM jsonb_to_recordset(v_fee_snapshot) AS fc(
            feeid BIGINT,
            feesaccount BIGINT,
            fromfees NUMERIC(18,4),
            tofees NUMERIC(18,4),
            sequenceid INT,
            feeaccount_oldbalance NUMERIC(18,4),
            feeaccount_lastupdate TIMESTAMPTZ
        )
    ),
    sender_fee_rows AS (
        SELECT
            p_transid AS transid,
            v_fromid AS accountid,
            -fc.fromfees AS amount,
            v_utcnow AS executedate,
            v_executionguid AS executionguid,
            (v_fromoldbalance - v_amount) - COALESCE(
                SUM(fc.fromfees) OVER (
                    ORDER BY fc.sequenceid, fc.feeid
                    ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
                ),
                0
            ) AS balancebefore,
            (v_fromoldbalance - v_amount) - SUM(fc.fromfees) OVER (
                ORDER BY fc.sequenceid, fc.feeid
                ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
            ) AS balanceafter,
            format('Sender Fee Debit - FeeID: %s - Sequence: %s', fc.feeid, fc.sequenceid) AS note,
            (fc.sequenceid * 3) AS processingorder
        FROM fee_rows fc
        WHERE fc.fromfees > 0
    ),
    receiver_fee_rows AS (
        SELECT
            p_transid AS transid,
            v_toid AS accountid,
            -fc.tofees AS amount,
            v_utcnow AS executedate,
            v_executionguid AS executionguid,
            (v_tooldbalance + v_amount) - COALESCE(
                SUM(fc.tofees) OVER (
                    ORDER BY fc.sequenceid, fc.feeid
                    ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
                ),
                0
            ) AS balancebefore,
            (v_tooldbalance + v_amount) - SUM(fc.tofees) OVER (
                ORDER BY fc.sequenceid, fc.feeid
                ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
            ) AS balanceafter,
            format('Receiver Fee Debit - FeeID: %s - Sequence: %s', fc.feeid, fc.sequenceid) AS note,
            (fc.sequenceid * 3) + 1 AS processingorder
        FROM fee_rows fc
        WHERE fc.tofees > 0
    ),
    fee_credit_rows AS (
        SELECT
            p_transid AS transid,
            fc.feesaccount AS accountid,
            (fc.fromfees + fc.tofees) AS amount,
            v_utcnow AS executedate,
            v_executionguid AS executionguid,
            fc.feeaccount_oldbalance + COALESCE(
                SUM(fc.fromfees + fc.tofees) OVER (
                    PARTITION BY fc.feesaccount
                    ORDER BY fc.sequenceid, fc.feeid
                    ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
                ),
                0
            ) AS balancebefore,
            fc.feeaccount_oldbalance + SUM(fc.fromfees + fc.tofees) OVER (
                PARTITION BY fc.feesaccount
                ORDER BY fc.sequenceid, fc.feeid
                ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
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
        FROM fee_rows fc
        WHERE fc.feesaccount IS NOT NULL
          AND (fc.fromfees > 0 OR fc.tofees > 0)
    ),
    log_entries AS (
        SELECT
            p_transid AS transid,
            v_fromid AS accountid,
            -v_amount AS amount,
            v_utcnow AS executedate,
            v_executionguid AS executionguid,
            v_fromoldbalance AS balancebefore,
            v_fromoldbalance - v_amount AS balanceafter,
            'Transaction Amount Debit'::TEXT AS note,
            1 AS processingorder

        UNION ALL

        SELECT
            p_transid,
            v_toid,
            v_amount,
            v_utcnow,
            v_executionguid,
            v_tooldbalance,
            v_tooldbalance + v_amount,
            'Transaction Amount Credit'::TEXT,
            2

        UNION ALL

        SELECT * FROM sender_fee_rows

        UNION ALL

        SELECT * FROM receiver_fee_rows

        UNION ALL

        SELECT * FROM fee_credit_rows
    )
    INSERT INTO balance_change_log (
        transid, accountid, amount, executedate, executionguid,
        balancebefore, balanceafter, note
    )
    SELECT
        transid,
        accountid,
        amount,
        executedate,
        executionguid,
        balancebefore,
        balanceafter,
        note
    FROM log_entries
    ORDER BY processingorder;

    UPDATE transaction_log
    SET
        isexecuted = TRUE,
        executiondate = v_utcnow,
        isclosed = TRUE,
        closingdate = v_utcnow,
        closedby = current_user
    WHERE transid = p_transid
      AND isexecuted = FALSE;

    GET DIAGNOSTICS v_rowcount = ROW_COUNT;
    IF v_rowcount = 0 THEN
        RAISE EXCEPTION '50002: The transaction % was already executed successfully.', p_transid;
    END IF;

    INSERT INTO transaction_execution_log (transid, executiondate, issuccessful, message, errornumber, errorstate, serviceid)
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

        INSERT INTO transaction_execution_log (transid, executiondate, issuccessful, message, errornumber, errorstate, serviceid)
        VALUES (COALESCE(p_transid, 0), timezone('utc', now()), FALSE, v_errmsg, v_errnum, NULL, v_transserviceid);

        RAISE;
END;
$$;
