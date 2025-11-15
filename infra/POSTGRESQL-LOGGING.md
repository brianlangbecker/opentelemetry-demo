# PostgreSQL Logging for Table Lock Detection

## Current Status

PostgreSQL logging configuration has been prepared but **requires manual activation** after Helm install due to limitations with the official PostgreSQL Docker image's environment variable handling.

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

## Current Limitation

**Issue**: The official PostgreSQL Docker image does not properly honor `POSTGRES_*` environment variables for logging configuration.

**Evidence**:
```bash
$ kubectl exec deployment/postgresql -c postgresql -- psql -U root -d otel -c "SHOW logging_collector;"
 logging_collector
-------------------
 off
```

The env vars are set, but PostgreSQL ignores them because they're not in the standard list that the entrypoint script processes.

## Workaround Options

### Option 1: Manual SQL Configuration (Temporary - Lost on Restart)
```bash
kubectl exec -n otel-demo deployment/postgresql -c postgresql -- psql -U root -d otel << 'EOF'
ALTER SYSTEM SET logging_collector = 'on';
ALTER SYSTEM SET log_directory = '/var/log/postgresql';
ALTER SYSTEM SET log_filename = 'postgresql.log';
ALTER SYSTEM SET log_lock_waits = 'on';
ALTER SYSTEM SET deadlock_timeout = '1s';
ALTER SYSTEM SET log_min_duration_statement = '1000';
ALTER SYSTEM SET log_line_prefix = '%t [%p] %u@%d ';
SELECT pg_reload_conf();
EOF
```

Then restart PostgreSQL:
```bash
kubectl rollout restart deployment/postgresql -n otel-demo
```

### Option 2: Custom PostgreSQL Image (Permanent Solution)
Create a custom PostgreSQL image that:
1. Extends the official postgres:17 image
2. Adds custom entrypoint that processes our logging env vars
3. Push to ECR and update Helm values to use custom image

### Option 3: Init Container (Alternative Permanent Solution)
Add init container that:
1. Creates `/var/lib/postgresql/data/postgresql.auto.conf` with settings
2. PostgreSQL reads this on startup

### Option 4: ConfigMap + Volume Mount
Create ConfigMap with `postgresql.conf` and mount it into the container.

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

- ✅ `infra/postgres-otel-configmap.yaml` - Added filelog receiver
- ✅ `infra/postgres-otel-sidecar-patch.yaml` - Added shared log volume
- ✅ `infra/otel-demo-values.yaml` - Added logging env vars
- ✅ `infra/otel-demo-values-aws.yaml` - Added logging env vars
- ✅ `infra/postgres-logging-config.yaml` - Standalone config (reference)
- ✅ `infra/POSTGRESQL-LOGGING.md` - This file

## Next Steps

Choose one of the workaround options above to actually enable file logging. Once enabled:

1. Verify log file exists:
   ```bash
   kubectl exec -n otel-demo deployment/postgresql -c postgresql -- ls -la /var/log/postgresql/
   ```

2. Check OTel collector is reading it:
   ```bash
   kubectl logs -n otel-demo deployment/postgresql -c otel-collector | grep filelog
   ```

3. Verify logs in Honeycomb:
   ```
   WHERE service.name = "postgresql-sidecar"
     AND component = "postgresql"
   CALCULATE COUNT
   ```

## Summary

**Current state**: Infrastructure ready, manual activation required
**Effort to activate**: 5 minutes (run SQL commands)
**Future state**: Need custom image or init container for permanent solution
**Value**: Direct visibility into table locks, deadlocks, slow queries with full SQL context
