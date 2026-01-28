-- Demo seed data for Atomic (PostgreSQL)
-- Inserts: services, service_transaction_types, accounts, fees

BEGIN;

-- Services
INSERT INTO services (serviceid, servicename, description)
VALUES (1, 'Wallet', 'Demo wallet service')
ON CONFLICT (serviceid) DO UPDATE
SET servicename = EXCLUDED.servicename,
    description = EXCLUDED.description;

-- Service transaction types
INSERT INTO service_transaction_types (
    typeid,
    serviceid,
    caption,
    description,
    needconfirmation,
    requiresreservation,
    minamount,
    maxamount
)
VALUES
    (1, 1, 'Transfer', 'Standard immediate transfer', FALSE, FALSE, 1.0000, 100000.0000)
ON CONFLICT (typeid, serviceid) DO UPDATE
SET caption = EXCLUDED.caption,
    description = EXCLUDED.description,
    needconfirmation = EXCLUDED.needconfirmation,
    requiresreservation = EXCLUDED.requiresreservation,
    minamount = EXCLUDED.minamount,
    maxamount = EXCLUDED.maxamount;

-- Accounts
INSERT INTO accounts (
    accountid,
    clientid,
    serviceid,
    operatinalid,
    subscriptiontype,
    status,
    createddate,
    balance,
    reservedbalance,
    lastupdate,
    expirationdate,
    minlimit,
    maxlimit,
    currencyid,
    accountname,
    identityid
)
VALUES
    -- Sender
    (1001, 10, 1, 'OP-1001', 1, 1, timezone('utc', now()), 1000.0000, 0.0000,
     timezone('utc', now()), timezone('utc', now()) + interval '3650 days',
     0.0000, 100000.0000, 1, 'Sender Account', 501),
    -- Receiver
    (2002, 20, 1, 'OP-2002', 1, 1, timezone('utc', now()), 100.0000, 0.0000,
     timezone('utc', now()), timezone('utc', now()) + interval '3650 days',
     0.0000, 100000.0000, 1, 'Receiver Account', 502),
    -- Fee collection
    (9001, 90, 1, 'OP-9001', 1, 1, timezone('utc', now()), 0.0000, 0.0000,
     timezone('utc', now()), timezone('utc', now()) + interval '3650 days',
     0.0000, 100000.0000, 1, 'Fees Account', 590)
ON CONFLICT (accountid) DO UPDATE
SET clientid = EXCLUDED.clientid,
    serviceid = EXCLUDED.serviceid,
    operatinalid = EXCLUDED.operatinalid,
    subscriptiontype = EXCLUDED.subscriptiontype,
    status = EXCLUDED.status,
    createddate = EXCLUDED.createddate,
    balance = EXCLUDED.balance,
    reservedbalance = EXCLUDED.reservedbalance,
    lastupdate = EXCLUDED.lastupdate,
    expirationdate = EXCLUDED.expirationdate,
    minlimit = EXCLUDED.minlimit,
    maxlimit = EXCLUDED.maxlimit,
    currencyid = EXCLUDED.currencyid,
    accountname = EXCLUDED.accountname,
    identityid = EXCLUDED.identityid;

-- Fees
-- Note: servicetranstypeid is compared against the transaction type in procs.
INSERT INTO fees (
    serviceid,
    servicetranstypeid,
    fromsubscriptiontypeid,
    tosubscriptiontypeid,
    sequenceid,
    feesaccount,
    fromfixedfees,
    frompercentfees,
    tofixedfees,
    topercentfees,
    applyinglimit,
    exemptionlimit,
    fromfeescation,
    fromfeesdescription,
    tofeescation,
    tofeesdescription
)
VALUES
    (1, 1, 1, 1, 1, 9001, 1.0000, 1.5000, 0.5000, 0.5000,
     0.0000, 999999999999.9999,
     'Sender Fees', 'Sender fixed + percent fees',
     'Receiver Fees', 'Receiver fixed + percent fees')
ON CONFLICT (serviceid, servicetranstypeid, fromsubscriptiontypeid, tosubscriptiontypeid, sequenceid) DO UPDATE
SET feesaccount = EXCLUDED.feesaccount,
    fromfixedfees = EXCLUDED.fromfixedfees,
    frompercentfees = EXCLUDED.frompercentfees,
    tofixedfees = EXCLUDED.tofixedfees,
    topercentfees = EXCLUDED.topercentfees,
    applyinglimit = EXCLUDED.applyinglimit,
    exemptionlimit = EXCLUDED.exemptionlimit,
    fromfeescation = EXCLUDED.fromfeescation,
    fromfeesdescription = EXCLUDED.fromfeesdescription,
    tofeescation = EXCLUDED.tofeescation,
    tofeesdescription = EXCLUDED.tofeesdescription;

COMMIT;
