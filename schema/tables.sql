-- ============================================================
-- Atomic (PostgreSQL)
-- Schema + Tables
-- ============================================================

-- Required for UUID generation (gen_random_uuid()).
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- -----------------------
-- Accounts
-- -----------------------
CREATE TABLE IF NOT EXISTS accounts (
    accountid        BIGSERIAL PRIMARY KEY,
    clientid         BIGINT,
    serviceid        SMALLINT,
    operatinalid     VARCHAR(50),
    subscriptiontype SMALLINT,
    status           SMALLINT,
    createddate      TIMESTAMPTZ DEFAULT timezone('utc', now()),
    balance          NUMERIC(18,4) NOT NULL DEFAULT 0,
    reservedbalance  NUMERIC(18,4) NOT NULL DEFAULT 0,   -- <-- missing in SQL Server tables.sql, used by procs
    lastupdate       TIMESTAMPTZ DEFAULT timezone('utc', now()),
    expirationdate   TIMESTAMPTZ,
    minlimit         NUMERIC(18,4),
    maxlimit         NUMERIC(18,4),
    currencyid       SMALLINT,
    accountname      VARCHAR(100),
    identityid       BIGINT
);

-- -----------------------
-- Services
-- -----------------------
CREATE TABLE IF NOT EXISTS services (
    serviceid    SMALLINT PRIMARY KEY,
    servicename  VARCHAR(50),
    description  TEXT
);

-- -----------------------
-- ServiceTransactionTypes (updated to match README + procs)
-- -----------------------
CREATE TABLE IF NOT EXISTS service_transaction_types (
    servicetranstypeid BIGSERIAL PRIMARY KEY,
    typeid             SMALLINT NOT NULL,
    serviceid          SMALLINT NOT NULL,
    caption            VARCHAR(50),
    description        TEXT,
    needconfirmation   BOOLEAN DEFAULT FALSE,

    -- These are REQUIRED by your stored procedures / README:
    requiresreservation BOOLEAN NOT NULL DEFAULT FALSE,
    minamount           NUMERIC(18,4),
    maxamount           NUMERIC(18,4),

    -- Optional uniqueness (recommended)
    CONSTRAINT uq_service_transaction_types UNIQUE (typeid, serviceid)
);

-- -----------------------
-- Service Currencies
-- -----------------------
CREATE TABLE IF NOT EXISTS service_currencies (
    serviceid  SMALLINT NOT NULL,
    currencyid SMALLINT NOT NULL,
    PRIMARY KEY (serviceid, currencyid)
);

-- -----------------------
-- Service Subscription Types
-- -----------------------
CREATE TABLE IF NOT EXISTS service_subscription_types (
    serviceid           SMALLINT NOT NULL,
    subscriptiontypeid  SMALLINT NOT NULL,
    subscriptionname    VARCHAR(50),
    description         TEXT,
    minlimit            NUMERIC(18,4),
    maxlimit            NUMERIC(18,4),
    currencyid          SMALLINT,
    trialduration       SMALLINT,
    maxaccountsperclient SMALLINT,
    PRIMARY KEY (serviceid, subscriptiontypeid)
);

-- -----------------------
-- Subscription Plans
-- -----------------------
CREATE TABLE IF NOT EXISTS subscription_plans (
    planid             SMALLINT PRIMARY KEY,
    serviceid          SMALLINT,
    subscriptiontypeid SMALLINT,
    planname           VARCHAR(50),
    duration           SMALLINT,
    price              NUMERIC(18,4),
    feesaccount        BIGINT
);

-- -----------------------
-- Fees (added feeid because procs reference FeeID)
-- -----------------------
CREATE TABLE IF NOT EXISTS fees (
    feeid                 BIGSERIAL PRIMARY KEY, -- <-- missing in SQL Server tables.sql, but used in execute_transaction logging
    serviceid             SMALLINT NOT NULL,
    servicetranstypeid    SMALLINT NOT NULL,
    fromsubscriptiontypeid SMALLINT NOT NULL,
    tosubscriptiontypeid   SMALLINT NOT NULL,
    sequenceid            SMALLINT NOT NULL,
    feesaccount           BIGINT,
    fromfixedfees         NUMERIC(18,4) DEFAULT 0,
    frompercentfees       NUMERIC(18,4) DEFAULT 0,
    fromfeescation        VARCHAR(50),
    fromfeesdescription   TEXT,
    tofixedfees           NUMERIC(18,4) DEFAULT 0,
    topercentfees         NUMERIC(18,4) DEFAULT 0,
    tofeescation          VARCHAR(50),
    tofeesdescription     TEXT,
    applyinglimit         NUMERIC(18,4) DEFAULT 0,
    exemptionlimit        NUMERIC(18,4) DEFAULT 999999999999.9999,

    CONSTRAINT uq_fees_business UNIQUE (
        serviceid,
        servicetranstypeid,
        fromsubscriptiontypeid,
        tosubscriptiontypeid,
        sequenceid
    )
);

-- -----------------------
-- TransactionLog
-- -----------------------
CREATE TABLE IF NOT EXISTS transaction_log (
    transid         BIGSERIAL PRIMARY KEY,
    transdate       TIMESTAMPTZ DEFAULT timezone('utc', now()),
    fromid          BIGINT,
    toid            BIGINT,
    amount          NUMERIC(18,4),
    duedate         TIMESTAMPTZ,
    isexecuted      BOOLEAN DEFAULT FALSE,
    isclosed        BOOLEAN DEFAULT FALSE,
    closingtransid  BIGINT,
    transtype       SMALLINT,
    createdby       VARCHAR(128),
    closedby        VARCHAR(128),
    closingdate     TIMESTAMPTZ,
    isconfirmed     BOOLEAN DEFAULT FALSE,
    confirmdate     TIMESTAMPTZ,
    confirmedby     VARCHAR(128),
    serviceid       SMALLINT,
    oprationrefno   VARCHAR(50),
    executiondate   TIMESTAMPTZ
);

-- -----------------------
-- BalanceChangeLog (missing in SQL Server tables.sql, required by execute_transaction)
-- -----------------------
CREATE TABLE IF NOT EXISTS balance_change_log (
    logid          BIGSERIAL PRIMARY KEY,
    transid        BIGINT NOT NULL,
    accountid      BIGINT NOT NULL,
    amount         NUMERIC(18,4) NOT NULL,
    executedate    TIMESTAMPTZ NOT NULL,
    executionguid  UUID NOT NULL,
    balancebefore  NUMERIC(18,4),
    balanceafter   NUMERIC(18,4),
    note           TEXT
);

-- -----------------------
-- TransactionExecutionLog (updated to match procs inserts)
-- -----------------------
CREATE TABLE IF NOT EXISTS transaction_execution_log (
    executionid   BIGSERIAL PRIMARY KEY,
    transid       BIGINT NOT NULL,
    executiondate TIMESTAMPTZ NOT NULL,
    issuccessful  BOOLEAN NOT NULL,
    message       TEXT,
    errornumber   INT,
    errorstate    INT,
    serviceid     SMALLINT
);
