-- ============================================================
-- Atomic (PostgreSQL) Indexes
-- ============================================================

-- TransactionLog fetch by TransID + cover read columns
CREATE INDEX IF NOT EXISTS ix_transaction_log_transid
ON transaction_log (transid)
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

-- BalanceChangeLog query by TransID
CREATE INDEX IF NOT EXISTS ix_balance_change_log_transid
ON balance_change_log (transid);

-- TransactionExecutionLog query by TransID
CREATE INDEX IF NOT EXISTS ix_transaction_execution_log_transid
ON transaction_execution_log (transid);
