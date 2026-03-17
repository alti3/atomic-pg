CREATE OR REPLACE FUNCTION create_transaction(
    p_fromid   BIGINT,
    p_toid     BIGINT,
    p_amount   NUMERIC(18,4),
    p_transtype SMALLINT,
    p_serviceid SMALLINT
)
RETURNS transaction_log
LANGUAGE plpgsql
AS $$
DECLARE
    v_transtypefound      BOOLEAN := FALSE;
    v_requiresreservation BOOLEAN;

    v_senderfound         BOOLEAN := FALSE;
    v_receiverfound       BOOLEAN := FALSE;

    v_fromsubscriptiontype SMALLINT;
    v_tosubscriptiontype   SMALLINT;
    v_fromserviceid        SMALLINT;
    v_toserviceid          SMALLINT;
    v_fromstatus           SMALLINT;
    v_tostatus             SMALLINT;
    v_fromcurrencyid       SMALLINT;
    v_tocurrencyid         SMALLINT;
    v_fromexpirationdate   TIMESTAMPTZ;
    v_toexpirationdate     TIMESTAMPTZ;

    v_fromfees             NUMERIC(18,4) := 0;
    v_currentbalance       NUMERIC(18,4);
    v_reservedbalance      NUMERIC(18,4);
    v_minlimit             NUMERIC(18,4);
    v_minallowedamount     NUMERIC(18,4);
    v_maxallowedamount     NUMERIC(18,4);

    v_availablebalance     NUMERIC(18,4);
    v_requiredamount       NUMERIC(18,4);

    v_row transaction_log;
    v_utcnow TIMESTAMPTZ := timezone('utc', now());
    v_rowcount INT;
BEGIN
    -- 1) Input validation
    IF p_amount <= 0 THEN
        RAISE EXCEPTION '50100: Amount must be greater than zero';
    END IF;

    -- 2) Read-only validation phase
    WITH transaction_type AS (
        SELECT
            stt.requiresreservation,
            stt.minamount,
            stt.maxamount
        FROM service_transaction_types stt
        WHERE stt.typeid = p_transtype
          AND stt.serviceid = p_serviceid
    ),
    sender AS (
        SELECT
            a.accountid,
            a.subscriptiontype,
            a.balance,
            a.reservedbalance,
            a.expirationdate,
            a.serviceid,
            a.minlimit,
            a.status,
            a.currencyid
        FROM accounts a
        WHERE a.accountid = p_fromid
    ),
    receiver AS (
        SELECT
            a.accountid,
            a.subscriptiontype,
            a.serviceid,
            a.status,
            a.currencyid,
            a.expirationdate
        FROM accounts a
        WHERE a.accountid = p_toid
    ),
    fee_total AS (
        SELECT COALESCE(SUM(
            CASE
                WHEN p_amount >= f.applyinglimit AND p_amount <= f.exemptionlimit
                THEN COALESCE(f.fromfixedfees, 0) + (COALESCE(f.frompercentfees, 0) * p_amount / 100)
                ELSE 0
            END
        ), 0) AS fromfees
        FROM fees f
        CROSS JOIN sender s
        CROSS JOIN receiver r
        WHERE f.serviceid = p_serviceid
          AND f.servicetranstypeid = p_transtype
          AND f.fromsubscriptiontypeid = s.subscriptiontype
          AND f.tosubscriptiontypeid = r.subscriptiontype
    )
    SELECT
        COALESCE(tt.requiresreservation IS NOT NULL, FALSE),
        tt.requiresreservation,
        tt.minamount,
        tt.maxamount,
        COALESCE(s.accountid IS NOT NULL, FALSE),
        s.subscriptiontype,
        s.balance,
        s.reservedbalance,
        s.expirationdate,
        s.serviceid,
        s.minlimit,
        s.status,
        s.currencyid,
        COALESCE(r.accountid IS NOT NULL, FALSE),
        r.subscriptiontype,
        r.serviceid,
        r.status,
        r.currencyid,
        r.expirationdate,
        COALESCE(ft.fromfees, 0)
    INTO
        v_transtypefound,
        v_requiresreservation,
        v_minallowedamount,
        v_maxallowedamount,
        v_senderfound,
        v_fromsubscriptiontype,
        v_currentbalance,
        v_reservedbalance,
        v_fromexpirationdate,
        v_fromserviceid,
        v_minlimit,
        v_fromstatus,
        v_fromcurrencyid,
        v_receiverfound,
        v_tosubscriptiontype,
        v_toserviceid,
        v_tostatus,
        v_tocurrencyid,
        v_toexpirationdate,
        v_fromfees
    FROM (SELECT 1 AS anchor) seed
    LEFT JOIN transaction_type tt ON TRUE
    LEFT JOIN sender s ON TRUE
    LEFT JOIN receiver r ON TRUE
    LEFT JOIN fee_total ft ON TRUE;

    IF NOT v_transtypefound THEN
        RAISE EXCEPTION '50101: Transaction type does not exist';
    END IF;

    IF v_minallowedamount IS NOT NULL AND p_amount < v_minallowedamount THEN
        RAISE EXCEPTION '50113: Amount is below minimum allowed for this transaction type';
    END IF;

    IF v_maxallowedamount IS NOT NULL AND p_amount > v_maxallowedamount THEN
        RAISE EXCEPTION '50114: Amount exceeds maximum allowed for this transaction type';
    END IF;

    IF NOT v_senderfound THEN
        RAISE EXCEPTION '50102: Sender account does not exist';
    END IF;

    IF v_fromstatus <> 1 THEN
        RAISE EXCEPTION '50103: Sender account is not active';
    END IF;

    IF v_fromexpirationdate < v_utcnow THEN
        RAISE EXCEPTION '50104: Sender account is expired';
    END IF;

    IF NOT v_receiverfound THEN
        RAISE EXCEPTION '50105: Receiver account does not exist';
    END IF;

    IF v_tostatus <> 1 THEN
        RAISE EXCEPTION '50106: Receiver account is not active';
    END IF;

    IF v_toexpirationdate < v_utcnow THEN
        RAISE EXCEPTION '50107: Receiver account is expired';
    END IF;

    IF v_fromserviceid <> p_serviceid OR v_toserviceid <> p_serviceid THEN
        RAISE EXCEPTION '50108: Service ID mismatch between accounts and transaction';
    END IF;

    IF v_fromcurrencyid <> v_tocurrencyid THEN
        RAISE EXCEPTION '50109: Currency mismatch between accounts';
    END IF;

    -- 3) Write phase: reserve only after all validation passes.
    IF v_requiresreservation THEN
        v_availablebalance := v_currentbalance - v_reservedbalance;
        v_requiredamount   := p_amount + v_fromfees;

        IF (v_availablebalance - v_requiredamount) < v_minlimit THEN
            RAISE EXCEPTION '50110: Insufficient available balance for reservation (considering minimum limit)';
        END IF;

        WITH reservation AS (
            UPDATE accounts
            SET reservedbalance = reservedbalance + v_requiredamount
            WHERE accountid = p_fromid
              AND balance = v_currentbalance
              AND reservedbalance = v_reservedbalance
            RETURNING 1
        )
        SELECT COUNT(*) INTO v_rowcount
        FROM reservation;

        IF v_rowcount = 0 THEN
            RAISE EXCEPTION '50111: Account balance changed during reservation';
        END IF;
    ELSE
        IF (v_currentbalance - p_amount - v_fromfees) < v_minlimit THEN
            RAISE EXCEPTION '50112: Insufficient balance for immediate transaction';
        END IF;
    END IF;

    WITH new_transaction AS (
        INSERT INTO transaction_log (
            fromid, toid, amount, serviceid, transtype,
            isexecuted, transdate
        )
        VALUES (
            p_fromid, p_toid, p_amount, p_serviceid, p_transtype,
            FALSE, v_utcnow
        )
        RETURNING *
    )
    SELECT * INTO v_row
    FROM new_transaction;

    RETURN v_row;
EXCEPTION
    WHEN OTHERS THEN
        -- Let caller handle; matches SQL Server THROW behavior
        RAISE;
END;
$$;
