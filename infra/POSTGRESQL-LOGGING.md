# PostgreSQL Logging for Table Lock Detection

## Current Status

PostgreSQL logging is **FULLY OPERATIONAL** using a Kubernetes Job-based activation approach. Logs are flowing to Honeycomb under the `postgresql-sidecar` dataset.

## What's Been Configured

### 1. Enhanced Logging Settings (Ready in Helm Values)
Both `otel-demo-values.yaml` and `otel-demo-values-aws.yaml` include:

```yaml
postgresql:
  envOverrides:
    - name: POSTGRES_LOGGING_COLLECTOR
      value: "on"
    - name: POSTGRES_LOG_DIRECTORY
      value: "/var/log/postgresql"
    - name: POSTGRES_LOG_FILENAME
      value: "postgresql.log"
    - name: POSTGRES_LOG_LOCK_WAITS
      value: "on"              # KEY: Logs table lock waits >1s
    - name: POSTGRES_DEADLOCK_TIMEOUT
      value: "1s"
    - name: POSTGRES_LOG_MIN_DURATION_STATEMENT
      value: "1000"            # Log slow queries >1s
    - name: POSTGRES_LOG_LINE_PREFIX
      value: "%t [%p] %u@%d "  # Better log format
    - name: POSTGRES_LOG_CHECKPOINTS
      value: "on"
    - name: POSTGRES_LOG_CONNECTIONS
      value: "on"
    - name: POSTGRES_LOG_DISCONNECTIONS
      value: "on"
```

### 2. OTel Collector Sidecar with Log Collection
- **File**: `infra/postgres-otel-configmap.yaml`
- **File**: `infra/postgres-otel-sidecar-patch.yaml`
- Includes `filelog` receiver configured to read `/var/log/postgresql/*.log`
- Parses PostgreSQL log format and extracts:
  - Lock wait information (pid, lock type, wait time)
  - Query durations
  - Error levels
  - Database/user context

### 3. Shared Log Volume
The sidecar patch adds:
- `emptyDir` volume named `postgres-logs`
- Mounted in PostgreSQL container at `/var/log/postgresql` (write)
- Mounted in OTel collector sidecar at `/var/log/postgresql` (read-only)

## How It Works

### Kubernetes Job Activation (Persistent Solution)

The logging configuration is activated by a Kubernetes Job (`postgres-logging-setup-job.yaml`) that:

1. Waits for PostgreSQL to be ready
2. Uses `ALTER SYSTEM` SQL commands to configure logging settings
3. Settings are written to `postgresql.auto.conf` (stored in the PVC)
4. Configuration persists across pod restarts
5. Job auto-cleans up after 5 minutes

**Deploy the Job**:
```bash
kubectl apply -f infra/postgres-logging-setup-job.yaml
```

**Verify Settings**:
```bash
kubectl exec -n otel-demo deployment/postgresql -c postgresql -- \
  psql -U root -d otel -c "SHOW logging_collector; SHOW log_lock_waits;"
```

**Settings Applied**:
- `logging_collector = on` - Enable file logging
- `log_directory = /var/log/postgresql` - Log file location
- `log_lock_waits = on` - Log lock waits >1s (KEY for table lock detection)
- `deadlock_timeout = 1s` - Trigger lock wait logging after 1s
- `log_min_duration_statement = 1000` - Log slow queries >1s
- `log_connections/disconnections = on` - Connection tracking
- `log_checkpoints = on` - Performance analysis

### Why Not Environment Variables?

The official PostgreSQL Docker image only processes a limited set of environment variables (POSTGRES_DB, POSTGRES_USER, POSTGRES_PASSWORD, POSTGRES_INITDB_ARGS). Custom logging env vars like `POSTGRES_LOG_LOCK_WAITS` are ignored by the entrypoint script.

### Why Not Init Container?

Init containers run BEFORE PostgreSQL's entrypoint. The entrypoint runs `initdb` which creates a fresh `postgresql.auto.conf`, overwriting anything written by the init container. The Job approach works because it runs AFTER PostgreSQL is fully initialized.

## What You Get When Logging Works

Once enabled, PostgreSQL will write logs to `/var/log/postgresql/postgresql.log` with entries like:

### Table Lock Example:
```
2025-11-11 02:33:00.123 UTC [12345] user@otel LOG: process 12345 still waiting for ShareLock on transaction 67890 after 1000.123 ms
2025-11-11 02:33:00.123 UTC [12345] user@otel STATEMENT: SELECT * FROM products ORDER BY name
```

### Slow Query Example:
```
2025-11-15 03:45:30.456 UTC [54321] user@otel LOG: duration: 2543.789 ms  statement: SELECT * FROM products WHERE name LIKE '%search%'
```

The OTel collector sidecar will:
1. Read these logs from the shared volume
2. Parse them and extract structured fields:
   - `level`: LOG, ERROR, WARNING
   - `pid`: PostgreSQL process ID
   - `user`: Database user
   - `database`: Database name
   - `message`: Full log message
   - `waiting_pid`: (for locks) Which process is waiting
   - `lock_type`: (for locks) Type of lock (ShareLock, ExclusiveLock, etc.)
   - `wait_time_ms`: (for locks) How long the wait has been
   - `query_duration_ms`: (for slow queries) Query execution time

3. Send to Honeycomb where you can query:
   ```
   WHERE service.name = "postgresql-sidecar"
     AND lock_type EXISTS
   GROUP BY lock_type, lock_object
   CALCULATE COUNT, MAX(wait_time_ms)
   ```

## Testing Lock Detection

Once logging is enabled, test with:

```sql
-- Terminal 1: Start long transaction with lock
BEGIN;
UPDATE products SET name = 'test' WHERE id = '1';
-- Don't COMMIT yet

-- Terminal 2: Try to read (will wait for lock)
SELECT * FROM products WHERE id = '1';
```

After 1 second, you'll see in logs:
```
LOG: process XXXXX still waiting for ShareLock on transaction YYYYY after 1000.XXX ms
```

## Files Modified/Created

- ✅ `infra/postgres-otel-configmap.yaml` - Filelog receiver with regex parsing
- ✅ `infra/postgres-otel-sidecar-patch.yaml` - Shared log volume + init container
- ✅ `infra/postgres-logging-setup-job.yaml` - **Job to activate logging** (apply this!)
- ✅ `infra/postgres-logging-init-configmap.yaml` - Init container config (currently unused)
- ✅ `infra/postgres-logging-init.sh` - Init script (reference, not used in final solution)
- ✅ `infra/otel-demo-values.yaml` - Logging env vars (documentation only)
- ✅ `infra/otel-demo-values-aws.yaml` - Logging env vars (documentation only)
- ✅ `infra/postgres-logging-config.yaml` - Standalone config (reference)
- ✅ `infra/POSTGRESQL-LOGGING.md` - This file

## Verification Steps

### 1. Check Log Files Exist
```bash
kubectl exec -n otel-demo deployment/postgresql -c postgresql -- \
  ls -la /var/log/postgresql/
```

Expected: `postgresql-YYYY-MM-DD_HHMMSS.log` files

### 2. Check OTel Collector is Reading Logs
```bash
kubectl logs -n otel-demo deployment/postgresql -c otel-collector --tail=50 | grep filelog
```

Expected: `Started watching file` and no regex errors

### 3. Verify Logs in Honeycomb
Query the `postgresql-sidecar` dataset:
```
WHERE service.name = "postgresql-sidecar"
  AND component = "postgresql"
GROUP BY level
CALCULATE COUNT
```

Expected: See LOG, FATAL levels with parsed fields (user, database, pid, timestamp)

### 4. Test Lock Wait Detection
```sql
-- Terminal 1: Start transaction with lock
kubectl exec -n otel-demo deployment/postgresql -c postgresql -- \
  psql -U root -d otel -c "BEGIN; UPDATE products SET name = 'test' WHERE id = '1';"
# Don't commit - leave it hanging

-- Terminal 2: Try to update same row (will wait)
kubectl exec -n otel-demo deployment/postgresql -c postgresql -- \
  psql -U root -d otel -c "UPDATE products SET name = 'test2' WHERE id = '1';"
```

After 1 second, check Honeycomb:
```
WHERE service.name = "postgresql-sidecar"
  AND body CONTAINS "still waiting for"
CALCULATE COUNT
```

Expected: Log entries with parsed `waiting_pid`, `lock_type`, `wait_time_ms` attributes

## Summary

**Current state**: ✅ Fully operational - logs flowing to Honeycomb
**Activation method**: Kubernetes Job with ALTER SYSTEM commands
**Persistence**: Settings stored in postgresql.auto.conf (survives restarts)
**Data available**: Connection logs, slow queries, lock waits, deadlocks, checkpoints
**Honeycomb dataset**: `postgresql-sidecar`
**Value**: Direct visibility into table locks, deadlocks, slow queries with full SQL context
