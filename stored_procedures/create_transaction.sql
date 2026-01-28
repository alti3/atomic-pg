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
    v_requiresreservation BOOLEAN;
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
    v_maxlimit             NUMERIC(18,4);
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

    -- 2) Transaction type validation
    SELECT stt.requiresreservation, stt.minamount, stt.maxamount
    INTO v_requiresreservation, v_minallowedamount, v_maxallowedamount
    FROM service_transaction_types stt
    WHERE stt.typeid = p_transtype
      AND stt.serviceid = p_serviceid;

    IF NOT FOUND THEN
        RAISE EXCEPTION '50101: Transaction type does not exist';
    END IF;

    IF v_minallowedamount IS NOT NULL AND p_amount < v_minallowedamount THEN
        RAISE EXCEPTION '50113: Amount is below minimum allowed for this transaction type';
    END IF;

    IF v_maxallowedamount IS NOT NULL AND p_amount > v_maxallowedamount THEN
        RAISE EXCEPTION '50114: Amount exceeds maximum allowed for this transaction type';
    END IF;

    -- 3) Sender account
    SELECT
        subscriptiontype,
        balance,
        reservedbalance,
        expirationdate,
        serviceid,
        minlimit,
        maxlimit,
        status,
        currencyid
    INTO
        v_fromsubscriptiontype,
        v_currentbalance,
        v_reservedbalance,
        v_fromexpirationdate,
        v_fromserviceid,
        v_minlimit,
        v_maxlimit,
        v_fromstatus,
        v_fromcurrencyid
    FROM accounts
    WHERE accountid = p_fromid;

    IF NOT FOUND THEN
        RAISE EXCEPTION '50102: Sender account does not exist';
    END IF;

    IF v_fromstatus <> 1 THEN
        RAISE EXCEPTION '50103: Sender account is not active';
    END IF;

    IF v_fromexpirationdate < v_utcnow THEN
        RAISE EXCEPTION '50104: Sender account is expired';
    END IF;

    -- 4) Receiver account
    SELECT
        subscriptiontype,
        serviceid,
        status,
        currencyid,
        expirationdate
    INTO
        v_tosubscriptiontype,
        v_toserviceid,
        v_tostatus,
        v_tocurrencyid,
        v_toexpirationdate
    FROM accounts
    WHERE accountid = p_toid;

    IF NOT FOUND THEN
        RAISE EXCEPTION '50105: Receiver account does not exist';
    END IF;

    IF v_tostatus <> 1 THEN
        RAISE EXCEPTION '50106: Receiver account is not active';
    END IF;

    IF v_toexpirationdate < v_utcnow THEN
        RAISE EXCEPTION '50107: Receiver account is expired';
    END IF;

    -- 5) Service & currency match
    IF v_fromserviceid <> p_serviceid OR v_toserviceid <> p_serviceid THEN
        RAISE EXCEPTION '50108: Service ID mismatch between accounts and transaction';
    END IF;

    IF v_fromcurrencyid <> v_tocurrencyid THEN
        RAISE EXCEPTION '50109: Currency mismatch between accounts';
    END IF;

    -- 6) Fee calculation (sender only)
    SELECT COALESCE(SUM(
        CASE
            WHEN p_amount >= f.applyinglimit AND p_amount <= f.exemptionlimit
            THEN COALESCE(f.fromfixedfees,0) + (COALESCE(f.frompercentfees,0) * p_amount / 100)
            ELSE 0
        END
    ), 0)
    INTO v_fromfees
    FROM fees f
    WHERE f.serviceid = p_serviceid
      AND f.servicetranstypeid = p_transtype
      AND f.fromsubscriptiontypeid = v_fromsubscriptiontype
      AND f.tosubscriptiontypeid = v_tosubscriptiontype;

    -- 7) Balance validation / reservation
    IF v_requiresreservation THEN
        v_availablebalance := v_currentbalance - v_reservedbalance;
        v_requiredamount   := p_amount + v_fromfees;

        IF (v_availablebalance - v_requiredamount) < v_minlimit THEN
            RAISE EXCEPTION '50110: Insufficient available balance for reservation (considering minimum limit)';
        END IF;

        UPDATE accounts
        SET reservedbalance = reservedbalance + v_requiredamount
        WHERE accountid = p_fromid
          AND balance = v_currentbalance
          AND reservedbalance = v_reservedbalance;

        GET DIAGNOSTICS v_rowcount = ROW_COUNT;
        IF v_rowcount = 0 THEN
            RAISE EXCEPTION '50111: Account balance changed during reservation';
        END IF;
    ELSE
        IF (v_currentbalance - p_amount - v_fromfees) < v_minlimit THEN
            RAISE EXCEPTION '50112: Insufficient balance for immediate transaction';
        END IF;
    END IF;

    -- 8) Create transaction record
    INSERT INTO transaction_log (
        fromid, toid, amount, serviceid, transtype,
        isexecuted, transdate
    )
    VALUES (
        p_fromid, p_toid, p_amount, p_serviceid, p_transtype,
        FALSE, v_utcnow
    )
    RETURNING * INTO v_row;

    RETURN v_row;
EXCEPTION
    WHEN OTHERS THEN
        -- Let caller handle; matches SQL Server THROW behavior
        RAISE;
END;
$$;
