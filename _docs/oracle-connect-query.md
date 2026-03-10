# Oracle 21c XE — Connect and Query Transactions

## Connection Details

| Property | Value |
|----------|-------|
| Host | `localhost` |
| Port | `1521` |
| Service | `XEPDB1` |
| User | `finance_user` (or value of `DB_USER`) |
| Password | value of `DB_PASSWORD` |
| SYS password | value of `ORACLE_SYS_PASSWORD` |

---

## Option 1 — SQL*Plus inside the container

```bash
docker exec -it oracle sqlplus finance_user/Finance123@XEPDB1
```

Once connected:

```sql
SELECT * FROM transactions FETCH FIRST 20 ROWS ONLY;
```

---

## Option 2 — External SQL client (DBeaver, SQL Developer, etc.)

Use an **Oracle JDBC** connection with:

```
JDBC URL:  jdbc:oracle:thin:@localhost:1521/XEPDB1
User:      finance_user
Password:  Finance123
```

---

## Useful Queries

List the 20 most recent transactions:

```sql
SELECT id, transaction_id, source_account, target_account,
       amount, currency, txn_type, status, created_at
FROM   transactions
ORDER  BY created_at DESC
FETCH  FIRST 20 ROWS ONLY;
```

Filter by status:

```sql
SELECT * FROM transactions
WHERE  status = 'SUSPICIOUS'
ORDER  BY created_at DESC;
```

Count by status:

```sql
SELECT status, COUNT(*) AS total
FROM   transactions
GROUP  BY status;
```

---

## AWS RDS Equivalent

When promoting to AWS RDS, use **Oracle 21c SE2**. The service name will be the DB identifier you set during RDS instance creation (e.g. `ORCL`). Update `DB_DSN` in your environment:

```
DB_DSN=<rds-endpoint>:1521/<db-name>
```

No code changes are required — `python-oracledb` (thin mode) connects to both local and RDS endpoints identically.
