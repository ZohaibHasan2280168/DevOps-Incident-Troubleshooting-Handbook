# 🚨 INC-006: Database Connection Pool Exhaustion Caused by Unclosed Sessions

| Metadata | Details |
| :--- | :--- |
| **Incident ID** | INC-006 |
| **Severity** | P1 (Widespread HTTP 500 Outage / Database Lockout) |
| **Subsystems** | PostgreSQL 16, SQLAlchemy ORM, FastAPI, PgBouncer |
| **Branch Reference** | `incident-06/db-connection-pool-exhaustion` |
| **Resolution Status** | 🟢 Resolved |

---

## 1. 🔍 Incident Summary & Symptoms

During a high-concurrency document processing period, the FastAPI backend abruptly began failing across all database-backed endpoints. Users encountered HTTP 500 Internal Server Errors, and background ingestion tasks timed out.

Application logs across backend instances were flooded with fatal connection exhaustion exceptions:

```log
psycopg2.OperationalError: FATAL: remaining connection slots are reserved for non-replication superuser connections
sqlalchemy.exc.TimeoutError: QueuePool limit of size 10 overflow 20 reached, connection timed out, timeout 30.00
ERROR: [FastAPI] Database session acquisition timeout after 30s. Dropping request.
```

Simultaneously, direct administrative logins via `psql` failed with `FATAL: sorry, too many clients already`.

---

## 2. 🧠 Root Cause Analysis (RCA)

### How Connection Leaks Occur
Relational databases like PostgreSQL allocate dedicated backend process memory for each active client connection (`max_connections`, typically set to 100 on standard RDS or containerized PostgreSQL instances). To avoid the expensive overhead of TCP handshakes and process forking for every query, the application uses an in-memory **Connection Pool** (SQLAlchemy `QueuePool`).

The incident was triggered by an application endpoint bug:
1. **Unclosed Session In Exception Blocks:** A document upload route opened a database session using `db = SessionLocal()`, queried the user profile, but encountered an unhandled S3 upload exception before reaching the `db.close()` statement.
2. **Abandoned Connections in `idle in transaction`:** Because the exception aborted the function execution early, the database socket was never closed or returned to the pool.
3. PostgreSQL kept the TCP connection open, holding locked resources and memory.
4. Over thousands of requests, every available connection slot in both the SQLAlchemy QueuePool and PostgreSQL `max_connections` was consumed by dead, abandoned sessions.

```
[ Incoming Requests ] ───> [ FastAPI Workers ]
                                   │
                                   ├─ Session 1 (Unhandled Error) ──> Abandoned (Holds Socket)
                                   ├─ Session 2 (Unhandled Error) ──> Abandoned (Holds Socket)
                                   └─ Session N ...               ──> 💥 max_connections=100 Exceeded!
                                                                      [ PostgreSQL Closes Door! ]
```

---

## 3. 🔬 Forensics: Database Real-Time Telemetry

Executing diagnostics directly on PostgreSQL revealed that 95% of connections were stuck in `idle` or `idle in transaction` states with start times dating back hours:

```sql
-- 1. Check connection distribution by state
SELECT count(*), state 
FROM pg_stat_activity 
GROUP BY state;
```
**Output:**
```
 count | state
-------+---------------------
     2 | active
    94 | idle in transaction  <--- Leaked connections!
     4 | idle
```

```sql
-- 2. Identify the longest running leaked queries
SELECT pid, now() - query_start AS duration, query, state 
FROM pg_stat_activity 
WHERE state != 'idle' 
ORDER BY duration DESC 
LIMIT 5;
```

---

## 4. 🛠️ The Production Fix & Remediation Runbook

### Step 1: Emergency Triage (Terminate Orphaned Connections)
Instantly reclaim connection slots without restarting the PostgreSQL database service:

```sql
-- Terminate all connections idle for more than 5 minutes
SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE state IN ('idle in transaction', 'idle')
  AND now() - state_change > interval '5 minutes'
  AND pid <> pg_backend_pid();
```

---

### Step 2: Code Refactoring (Enforce Context Managers / Yield Dependency)
Replaced manual session management with FastAPI's `Depends(get_db)` utilizing a clean generator and `finally` block to guarantee connection release even during unhandled exceptions:

```python
# app/database.py - Guarantees session release
def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()  # <-- Always executed, even if endpoint throws an unhandled exception!
```

---

### Step 3: Pool Configuration Hardening
Hardened SQLAlchemy engine pool parameters in `app/database.py` with automatic connection reclamation, recycling, and pre-pings:

```python
from sqlalchemy import create_engine

engine = create_engine(
    DATABASE_URL,
    pool_size=15,             # Baseline connections to maintain
    max_overflow=25,          # Extra connections during momentary spikes
    pool_timeout=30,          # Seconds to wait before giving up
    pool_recycle=1800,        # Re-create connections older than 30 mins (prevents stale FDs)
    pool_pre_ping=True        # Tests liveness of connection with SELECT 1 before handing to app
)
```

---

## 5. 🛡️ Prevention & Production Best Practices

1. **Enable Connection Pooler (PgBouncer):** In high-scale Kubernetes or serverless environments where thousands of ephemeral pods spin up, place **PgBouncer** in front of PostgreSQL to multiplex thousands of client connections into a small pool of 20-30 database connections.
2. **Postgres `idle_in_transaction_session_timeout`:** Configure PostgreSQL server configuration:
   ```sql
   ALTER SYSTEM SET idle_in_transaction_session_timeout = '60000'; -- Terminate after 60s
   SELECT pg_reload_conf();
   ```
3. **Observability Alerts:** Provision Prometheus `postgres_exporter` alerts when `pg_stat_activity_count / max_connections > 0.8` (80% threshold).
