# Atomic (PostgreSQL)

Atomic is a high-integrity financial transaction engine that runs **entirely inside PostgreSQL** using **stored logic (PL/pgSQL functions)**. It executes transfers with configurable fees, optional balance reservation (two-phase execution), strong validation, and full audit logging — designed for correctness and high throughput.

> This repository originally targeted SQL Server (T-SQL). It has been converted to PostgreSQL while keeping the same core behavior and error codes.

---

## Features

- **Multiple Services**: define separate financial services and configurations.
- **Account Management**: balances, reserved balances, limits, currency, expiration, status.
- **Transaction Types per Service**: configure whether a type requires reservation, and enforce min/max transaction amount.
- **Flexible Fees**:
  - fixed + percentage fees
  - fees applied to sender and/or receiver
  - multiple fee rows per transaction type
  - strict processing order via `SequenceID`
  - optional fee-collection accounts
- **Two-phase Reserved Transactions**:
  - `create_transaction` optionally reserves balance (amount + sender fees)
  - `execute_transaction` finalizes the transfer and releases reservation
- **Optimistic Concurrency Control**:
  - `LastUpdate` + balance checks during updates
  - detects concurrent modification and aborts safely
- **Comprehensive Logging**:
  - `balance_change_log` for an ordered balance change timeline
  - `transaction_execution_log` for success/failure and error details

---

## Project Structure

```
Atomic/
├── schema/
│   ├── tables.sql             # PostgreSQL schema (tables, constraints)
│   ├── indexes.sql            # PostgreSQL indexes
├── stored_procedures/
│   ├── create_transaction.sql  # Creates a transaction record and optionally reserves funds.
│   └── execute_transaction.sql # Executes a pending transaction, applies fees, moves balances, and logs.
```

---

## Requirements

- PostgreSQL **11+** (recommended 13+)
- Extension: `pgcrypto` (for UUID generation)

---

## Setup / Installation

### 1) Create database (example)

```sql
CREATE DATABASE atomic;
\c atomic
````

### 2) Install required extension

```sql
CREATE EXTENSION IF NOT EXISTS pgcrypto;
```

### 3) Create schema & tables

Run:

```bash
psql -d atomic -f schema/tables.sql
```

### 4) Create indexes

```bash
psql -d atomic -f schema/indexes.sql
```

### 5) Create functions (stored procedures)

```bash
psql -d atomic -f stored_procedures/create_transaction.sql
psql -d atomic -f stored_procedures/execute_transaction.sql
```

---

## Core Database Tables

1. **accounts**

   * stores balance and reserved balance, limits, status, currency, service, expiration, etc.
2. **transaction_log**

   * records all transactions (created + executed state)
3. **fees**

   * defines fee rules per service + transaction type + subscription types
4. **balance_change_log**

   * ordered balance-change audit entries (main transfer + fee debits/credits)
5. **transaction_execution_log**

   * records each execution attempt (success/failure + message + error code)
6. **service_transaction_types**

   * defines per-service transaction types:

     * reservation requirement
     * min/max allowed transaction amount

---

## Transaction Flow

Atomic supports two transaction flows:

### 1) Immediate Transactions

* No reservation
* `create_transaction` only records the transaction after validation
* `execute_transaction` moves balances and logs everything

### 2) Reserved Transactions (Two-Phase)

* Reservation required
* `create_transaction` reserves `(Amount + SenderFees)` into `accounts.reservedbalance`
* `execute_transaction` verifies reserved balance, releases it, then applies final balances and logs

---

## Stored Logic (PostgreSQL Functions)

PostgreSQL uses functions instead of SQL Server procedures. Atomic provides:

### 1) `create_transaction(...) -> transaction_log`

Creates a transaction record and optionally reserves funds.

**Signature**

```sql
create_transaction(
  p_fromid BIGINT,
  p_toid BIGINT,
  p_amount NUMERIC(18,4),
  p_transtype SMALLINT,
  p_serviceid SMALLINT
) RETURNS transaction_log
```

**What it does**

* validates amount
* validates transaction type/service and amount limits (`minamount`, `maxamount`)
* validates sender/receiver accounts (existence, status=1, not expired)
* validates service and currency match
* calculates **sender fees** needed for reservation validation
* if reservation required:

  * checks available balance and minlimit
  * updates `reservedbalance` with optimistic concurrency
* inserts into `transaction_log`
* returns the inserted `transaction_log` row

---

### 2) `execute_transaction(transid) -> text`

Executes a pending transaction, applies fees, moves balances, and logs.

**Signature**

```sql
execute_transaction(p_transid BIGINT) RETURNS TEXT
```

**What it does**

* validates transaction exists and is not already executed
* validates sender/receiver accounts (status, expiry, service, currency)
* calculates **all applicable fees** (sender + receiver)
* validates fee accounts (exist/active/not expired/currency match)
* updates fee accounts with optimistic concurrency
* checks new balances against account limits
* if reservation required:

  * verifies reserved balance covers `(amount + sender fees)`
  * reduces reserved balance
* writes ordered entries into `balance_change_log`
* updates sender + receiver balances with optimistic concurrency
* marks `transaction_log.isexecuted=true` and closes the transaction
* writes a success entry into `transaction_execution_log`
* returns `'success'`

---

## Usage Examples

### Creating a transaction

Because PostgreSQL is strict about types, you should **cast** arguments to match the function signature:

```sql
SELECT *
FROM create_transaction(
  1001::bigint,
  2002::bigint,
  50.0000::numeric(18,4),
  1::smallint,
  10::smallint
);
```

If you prefer not to cast every time, add an overload wrapper:

```sql
CREATE OR REPLACE FUNCTION create_transaction(
  p_fromid integer,
  p_toid integer,
  p_amount numeric,
  p_transtype integer,
  p_serviceid integer
)
RETURNS transaction_log
LANGUAGE sql
AS $$
  SELECT * FROM create_transaction(
    p_fromid::bigint,
    p_toid::bigint,
    p_amount::numeric(18,4),
    p_transtype::smallint,
    p_serviceid::smallint
  );
$$;
```

### Executing a transaction

```sql
SELECT execute_transaction(12345::bigint);
```

---

## Error Codes

PostgreSQL does not support `THROW <number>, <message>, <state>` like SQL Server.
Atomic preserves your existing error codes by raising messages like:

```
50014: Transaction will make sender's balance outside allowed limits...
```

`execute_transaction()` also attempts to parse the leading 5-digit code and stores it in:

* `transaction_execution_log.errornumber`

### create_transaction Error Codes

| Error Code | Meaning                                                                    |
| ---------- | -------------------------------------------------------------------------- |
| 50100      | Amount must be greater than zero                                           |
| 50101      | Transaction type does not exist (for this service)                         |
| 50102      | Sender account does not exist                                              |
| 50103      | Sender account is not active                                               |
| 50104      | Sender account is expired                                                  |
| 50105      | Receiver account does not exist                                            |
| 50106      | Receiver account is not active                                             |
| 50107      | Receiver account is expired                                                |
| 50108      | Service ID mismatch between accounts and transaction                       |
| 50109      | Currency mismatch between accounts                                         |
| 50110      | Insufficient available balance for reservation (considering minimum limit) |
| 50111      | Account changed during reservation (optimistic concurrency)                |
| 50112      | Insufficient balance for immediate transaction                             |
| 50113      | Amount below minimum allowed for this transaction type                     |
| 50114      | Amount exceeds maximum allowed for this transaction type                   |

### execute_transaction Error Codes

| Error Code | Meaning                                                          |
| ---------- | ---------------------------------------------------------------- |
| 50000      | Invalid Transaction ID: NULL                                     |
| 50001      | Transaction ID not found                                         |
| 50002      | Transaction already executed                                     |
| 50003      | Cannot transfer to same account                                  |
| 50004      | Sender account does not exist                                    |
| 50005      | Sender account is not active                                     |
| 50006      | Receiver account does not exist                                  |
| 50007      | Receiver account is not active                                   |
| 50008      | Service IDs do not match                                         |
| 50009      | Currency mismatch                                                |
| 50010      | Sender expired                                                   |
| 50011      | Receiver expired                                                 |
| 50012      | Fee account invalid (missing/inactive/expired/currency mismatch) |
| 50013      | Fee account changed during execution                             |
| 50014      | Sender balance would violate limits                              |
| 50015      | Receiver balance would violate limits                            |
| 50016      | Sender account changed during execution                          |
| 50017      | Receiver account changed during execution                        |
| 50020      | Insufficient reserved balance                                    |

---

## Concurrency Model

Atomic uses **optimistic concurrency control**:

* each account has `lastupdate` and balance checks in `UPDATE ... WHERE ...`
* if another transaction modifies the row, the update affects 0 rows and the function aborts with a specific error code

This prevents double-spend and maintains balance correctness.

---

## Schema Notes (PostgreSQL Conversion)

During conversion from SQL Server, the following schema gaps were fixed to match the logic:

* `accounts.reservedbalance` was added (required by reservation flow)
* `service_transaction_types` gained:

  * `requiresreservation`
  * `minamount`, `maxamount`
  * unique constraint `(typeid, serviceid)`
* `fees` gained a surrogate `feeid` (needed for detailed fee logging)
* `balance_change_log` and enhanced `transaction_execution_log` were added to support the stored logic

---

## Performance Notes

* Use the included indexes (`schema/indexes.sql`)
* Keep `accounts` and `fees` well indexed for high TPS (Transactions Per Second)
* Consider running with:

  * `synchronous_commit = on` for maximum durability
  * or `off` for higher throughput (trade-off: durability on crash)
* If you need even higher throughput, a variant using `SELECT ... FOR UPDATE` row-locking can be provided.

---

## License

MIT License

---

## Maintainers / Contribution

* PRs welcome
