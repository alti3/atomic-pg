-- ============================================================
-- Atomic (PostgreSQL) Indexes
-- ============================================================

-- TransLog fetch by TransID + cover read columns
CREATE INDEX IF NOT EXISTS ix_translog_transid
ON translog (transid)
INCLUDE (fromid, toid, amount, serviceid, transtype, isexecuted);

-- Accounts fetch by AccountID + cover read columns
CREATE INDEX IF NOT EXISTS ix_accounts_accountid
ON accounts (accountid)
INCLUDE (subscriptiontype, balance, reservedbalance, expirationdate, serviceid,
         minlimit, maxlimit, lastupdate, status, currencyid);

-- Accounts concurrency lookups
CREATE INDEX IF NOT EXISTS ix_accounts_accountid_lastupdate_balance
ON accounts (accountid, lastupdate, balance);

-- Fees filtering
CREATE INDEX IF NOT EXISTS ix_fees_service_subscriptiontypes
ON fees (serviceid, servicetranstypeid, fromsubscriptiontypeid, tosubscriptiontypeid)
INCLUDE (feeid, feesaccount, sequenceid, applyinglimit, exemptionlimit,
         fromfixedfees, frompercentfees, tofixedfees, topercentfees);

-- ChangeBalanceLog query by TransID
CREATE INDEX IF NOT EXISTS ix_changebalancelog_transid
ON changebalancelog (transid);

-- TransExecutionLog query by TransID
CREATE INDEX IF NOT EXISTS ix_transexecutionlog_transid
ON transexecutionlog (transid);