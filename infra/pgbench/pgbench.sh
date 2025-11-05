#!/bin/bash
# Simple pgbench runner - executes inside the PostgreSQL pod
#
# Usage:
#   ./pgbench.sh light              # 10k transactions (~30s)
#   ./pgbench.sh normal             # 500k transactions (~5-10 min)
#   ./pgbench.sh beast              # 5M transactions per client (~30+ min)
#   ./pgbench.sh accounting         # Target accounting tables (REAL blast radius)
#   ./pgbench.sh connection-exhaust # Exhaust connection pool
#   ./pgbench.sh table-lock         # Lock critical table
#   ./pgbench.sh slow-query         # Run expensive queries
#   ./pgbench.sh demo               # Run all scenarios sequentially
#

set -e

LOAD_LEVEL="${1:-normal}"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}=========================================="
echo "pgbench PostgreSQL Load Generator"
echo -e "==========================================${NC}"

# Get PostgreSQL pod
POD=$(kubectl get pods -n otel-demo -l app.kubernetes.io/component=postgresql -o jsonpath='{.items[0].metadata.name}')

if [ -z "$POD" ]; then
    echo -e "${RED}Error: PostgreSQL pod not found${NC}"
    exit 1
fi

echo -e "${GREEN}Using PostgreSQL pod: $POD${NC}"

# Verify pgbench is available
if ! kubectl exec -n otel-demo $POD -- which pgbench >/dev/null 2>&1; then
    echo -e "${RED}Error: pgbench not found in PostgreSQL pod${NC}"
    echo "The OpenTelemetry demo PostgreSQL image should include pgbench by default."
    exit 1
fi

PGBENCH_VERSION=$(kubectl exec -n otel-demo $POD -- pgbench --version 2>&1 | head -1)
echo -e "${GREEN}pgbench version: $PGBENCH_VERSION${NC}"
echo ""

# Configure load based on level
case $LOAD_LEVEL in
    light)
        CLIENTS=10
        TRANSACTIONS=1000
        SCALE=10
        echo -e "${GREEN}Load Level: LIGHT${NC}"
        echo "  - 10 clients x 1,000 txns = 10,000 total"
        echo "  - Scale: 10 (1M rows)"
        echo "  - Duration: ~30 seconds"
        ;;
    normal)
        CLIENTS=50
        TRANSACTIONS=10000
        SCALE=100
        echo -e "${YELLOW}Load Level: NORMAL${NC}"
        echo "  - 50 clients x 10,000 txns = 500,000 total"
        echo "  - Scale: 100 (10M rows)"
        echo "  - Duration: ~5-10 minutes"
        ;;
    beast)
        CLIENTS=100
        TRANSACTIONS=50000
        SCALE=200
        echo -e "${RED}Load Level: BEAST MODE${NC}"
        echo "  - 100 clients x 50,000 txns = 5,000,000 total"
        echo "  - Scale: 200 (20M rows)"
        echo "  - Duration: ~30+ minutes"
        echo "  - WARNING: WILL stress the database!"
        ;;
    accounting)
        echo -e "${RED}Load Level: ACCOUNTING TABLE TARGET${NC}"
        echo "  - Targets REAL application tables (order, orderitem)"
        echo "  - Creates DIRECT contention with accounting service"
        echo "  - 50 clients x 10,000 txns = 500,000 total"
        echo "  - Expected: REAL blast radius cascade!"
        echo ""
        echo -e "${YELLOW}This will:${NC}"
        echo "  1. INSERT into 'order' table (same as accounting service)"
        echo "  2. INSERT into 'orderitem' table (with foreign keys)"
        echo "  3. Query both tables (simulate reporting)"
        echo "  4. Compete directly with accounting for table locks"
        echo ""
        echo -e "${RED}Expected blast radius:${NC}"
        echo "  - PostgreSQL: High CPU/memory, table lock contention"
        echo "  - accounting: Queries VERY slow, Kafka backlog grows"
        echo "  - checkout: Timeouts waiting for accounting"
        echo "  - frontend: Failed checkouts"
        echo ""

        read -p "Continue? (y/n) " -n 1 -r
        echo ""
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo "Aborted."
            exit 0
        fi

        echo ""
        echo -e "${BLUE}Copying custom workload to PostgreSQL pod...${NC}"
        kubectl cp accounting-load.sql otel-demo/$POD:/tmp/accounting-load.sql

        echo -e "${BLUE}Starting accounting table load test...${NC}"
        echo -e "${YELLOW}Press Ctrl+C to stop${NC}"
        echo ""

        kubectl exec -n otel-demo $POD -- pgbench \
            -c 50 \
            -j 25 \
            -t 10000 \
            -f /tmp/accounting-load.sql \
            -P 10 \
            -r \
            -U root \
            otel

        echo ""
        echo -e "${GREEN}==========================================="
        echo "Accounting load test complete!"
        echo -e "==========================================${NC}"
        exit 0
        ;;
    init)
        echo -e "${BLUE}Initializing pgbench tables...${NC}"
        kubectl exec -n otel-demo $POD -- pgbench -i -s 40 -U root otel
        echo -e "${GREEN}Initialization complete!${NC}"
        exit 0
        ;;
    clean)
        echo -e "${YELLOW}Cleaning up pgbench tables...${NC}"
        kubectl exec -n otel-demo $POD -- psql -U root otel -c "DROP TABLE IF EXISTS pgbench_accounts, pgbench_branches, pgbench_tellers, pgbench_history CASCADE;"
        echo -e "${GREEN}Cleanup complete!${NC}"
        exit 0
        ;;
    status)
        echo -e "${BLUE}Checking pgbench tables...${NC}"
        kubectl exec -n otel-demo $POD -- psql -U root otel -c "\dt pgbench_*"
        kubectl exec -n otel-demo $POD -- psql -U root otel -c "SELECT pg_size_pretty(pg_total_relation_size('pgbench_accounts')) as accounts_size, count(*) as row_count FROM pgbench_accounts;" 2>/dev/null || echo "Tables not initialized"
        exit 0
        ;;
    connection-exhaust)
        echo -e "${RED}Scenario: CONNECTION EXHAUSTION${NC}"
        echo "  - Opens 90 connections (90% of max_connections=100)"
        echo "  - Holds connections for 5 minutes (300 seconds)"
        echo "  - Purpose: Exhaust connection pool → all services fail to connect"
        echo "  - Expected: accounting, checkout, frontend ALL show connection errors"
        echo ""
        echo -e "${YELLOW}Blast radius cascade:${NC}"
        echo "  1. Database connections → 90/100 (90% utilized)"
        echo "  2. Accounting can't connect → errors pile up"
        echo "  3. Checkout can't connect → API failures"
        echo "  4. Frontend shows 'Database unavailable' errors"
        echo ""
        read -p "Continue? (y/n) " -n 1 -r
        echo ""
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo "Aborted."
            exit 0
        fi

        echo -e "${BLUE}Opening 90 connections for 5 minutes...${NC}"
        echo "Monitor in Honeycomb:"
        echo "  - accounting: 'too many clients' errors"
        echo "  - checkout: connection timeouts"
        echo "  - frontend: 500 errors"
        echo ""

        # Create a simple SQL file that just sleeps
        kubectl exec -n otel-demo $POD -c postgresql -- bash -c 'cat > /tmp/hold-connection.sql << EOF
SELECT pg_sleep(300);
EOF'

        echo -e "${YELLOW}Starting 90 pgbench clients (each holds 1 connection)...${NC}"
        # Run pgbench as a detached process INSIDE the pod to avoid kubectl timeout
        kubectl exec -n otel-demo $POD -c postgresql -- bash -c '
nohup pgbench \
    -c 90 \
    -j 1 \
    -T 300 \
    -f /tmp/hold-connection.sql \
    -n \
    -U root \
    otel > /tmp/connection-exhaust.log 2>&1 &
echo $! > /tmp/connection-exhaust.pid
'

        sleep 3  # Give time for connections to establish
        
        echo ""
        echo -e "${RED}90 database connections are now HELD for 5 minutes!${NC}"
        echo ""
        
        # Monitor connection count every 30 seconds for 5 minutes
        for i in {1..10}; do
            sleep 30
            CONN_COUNT=$(kubectl exec -n otel-demo $POD -c postgresql -- psql -U root -d otel -t -c "SELECT count(*) FROM pg_stat_activity;" 2>/dev/null | xargs)
            echo "[$((i*30))s / 300s] Active connections: $CONN_COUNT/100"

            # Check if pgbench is still running
            PGBENCH_RUNNING=$(kubectl exec -n otel-demo $POD -c postgresql -- bash -c 'test -f /tmp/connection-exhaust.pid && ps -p $(cat /tmp/connection-exhaust.pid) > /dev/null 2>&1 && echo "yes" || echo "no"')
            if [ "$PGBENCH_RUNNING" = "no" ]; then
                echo -e "${YELLOW}⚠ pgbench process ended early${NC}"
                break
            fi
        done

        echo ""
        echo -e "${GREEN}Connection exhaustion test complete!${NC}"

        # Show pgbench output
        echo ""
        echo "pgbench output:"
        kubectl exec -n otel-demo $POD -c postgresql -- cat /tmp/connection-exhaust.log 2>/dev/null || echo "No output file"
        exit 0
        ;;
    table-lock)
        echo -e "${RED}Scenario: TABLE LOCK - ORDER & PRODUCTS TABLES${NC}"
        echo "  - Locks 'order' table with exclusive lock (REAL blast radius!)"
        echo "  - Locks 'products' table with exclusive lock (product-catalog impact!)"
        echo "  - Holds locks for 10 MINUTES (sustained blast radius)"
        echo "  - Purpose: Block accounting service writes AND product-catalog reads"
        echo "  - Expected: Accounting blocked, checkout timeouts, product-catalog blocked, frontend errors"
        echo ""
        echo -e "${YELLOW}Blast radius cascade:${NC}"
        echo "  1. ORDER table locked → accounting writes blocked"
        echo "  2. PRODUCTS table locked → product-catalog queries blocked"
        echo "  3. Checkout can't get products → API failures"
        echo "  4. Kafka backlog grows → accounting memory increases"
        echo "  5. Frontend timeouts → User-visible errors"
        echo ""
        read -p "Continue? (y/n) " -n 1 -r
        echo ""
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo "Aborted."
            exit 0
        fi

        echo -e "${BLUE}Locking 'order' and 'products' tables for 10 minutes...${NC}"
        echo "Monitor in Honeycomb:"
        echo "  - accounting service: query duration spikes, blocked transactions"
        echo "  - product-catalog service: query duration spikes, blocked queries"
        echo "  - checkout service: product lookup failures"
        echo "  - frontend: error rates increase"
        echo ""
        echo -e "${YELLOW}Starting persistent lock session inside pod...${NC}"
        echo ""

        # Run psql as a detached process INSIDE the pod to avoid kubectl timeout
        # This creates a background process inside the PostgreSQL container
        kubectl exec -n otel-demo $POD -c postgresql -- bash -c '
nohup psql -U root otel > /tmp/table-lock-output.log 2>&1 <<EOF &
BEGIN;
LOCK TABLE "order" IN ACCESS EXCLUSIVE MODE;
LOCK TABLE products IN ACCESS EXCLUSIVE MODE;
SELECT '\''Lock acquired on order and products tables'\'' as status, NOW() as lock_time;
SELECT pg_sleep(600);
COMMIT;
SELECT '\''Lock released'\'' as status, NOW() as release_time;
EOF
echo $! > /tmp/table-lock.pid
'

        # Give it time to acquire lock
        sleep 5
        
        # Verify locks are active
        ORDER_LOCKED=$(kubectl exec -n otel-demo $POD -c postgresql -- psql -U root -d otel -t -c "SELECT COUNT(*) FROM pg_locks WHERE locktype = 'relation' AND relation = '\"order\"'::regclass;" 2>/dev/null | xargs || echo "0")
        PRODUCTS_LOCKED=$(kubectl exec -n otel-demo $POD -c postgresql -- psql -U root -d otel -t -c "SELECT COUNT(*) FROM pg_locks WHERE locktype = 'relation' AND relation = 'products'::regclass;" 2>/dev/null | xargs || echo "0")

        if [ "$ORDER_LOCKED" -gt "0" ] && [ "$PRODUCTS_LOCKED" -gt "0" ]; then
            echo -e "${RED}✓ Order and Products tables are now LOCKED for 10 MINUTES!${NC}"
        else
            echo -e "${YELLOW}⚠ Warning: Locks may not be active (order: $ORDER_LOCKED, products: $PRODUCTS_LOCKED)${NC}"
        fi

        echo ""
        
        # Monitor and show status every 30 seconds for 10 minutes
        for i in {1..20}; do
            sleep 30
            ORDER_LOCKED=$(kubectl exec -n otel-demo $POD -c postgresql -- psql -U root -d otel -t -c "SELECT COUNT(*) FROM pg_locks WHERE locktype = 'relation' AND relation = '\"order\"'::regclass;" 2>/dev/null | xargs || echo "0")
            PRODUCTS_LOCKED=$(kubectl exec -n otel-demo $POD -c postgresql -- psql -U root -d otel -t -c "SELECT COUNT(*) FROM pg_locks WHERE locktype = 'relation' AND relation = 'products'::regclass;" 2>/dev/null | xargs || echo "0")
            WAITING=$(kubectl exec -n otel-demo $POD -c postgresql -- psql -U root -d otel -t -c "SELECT COUNT(*) FROM pg_stat_activity WHERE wait_event_type = 'Lock' AND datname = 'otel';" 2>/dev/null | xargs || echo "0")
            ORDER_COUNT=$(kubectl exec -n otel-demo $POD -c postgresql -- psql -U root -d otel -t -c "SELECT COUNT(*) FROM \"order\";" 2>/dev/null | xargs || echo "0")
            PRODUCTS_COUNT=$(kubectl exec -n otel-demo $POD -c postgresql -- psql -U root -d otel -t -c "SELECT COUNT(*) FROM products;" 2>/dev/null | xargs || echo "0")
            echo "[$((i*30))s / 600s] Order lock: $ORDER_LOCKED | Products lock: $PRODUCTS_LOCKED | Waiting: $WAITING | Orders: $ORDER_COUNT | Products: $PRODUCTS_COUNT"

            # Check if lock process is still alive
            if [ "$ORDER_LOCKED" -eq "0" ] && [ "$PRODUCTS_LOCKED" -eq "0" ]; then
                echo -e "${YELLOW}⚠ Locks released early! Exiting monitor loop.${NC}"
                break
            fi
        done

        echo ""
        echo -e "${GREEN}Table locks released!${NC}"
        echo -e "${GREEN}Table lock test complete!${NC}"

        # Show final output
        echo ""
        echo "Lock session output:"
        kubectl exec -n otel-demo $POD -c postgresql -- cat /tmp/table-lock-output.log 2>/dev/null || echo "No output file"
        exit 0
        ;;
    slow-query)
        echo -e "${RED}Scenario: SLOW QUERY / FULL TABLE SCAN${NC}"
        echo "  - Runs expensive full table scan queries"
        echo "  - 20 clients running for 5 minutes"
        echo "  - Purpose: Create query-level slowdown"
        echo "  - Expected: High CPU, slow query times, no connection errors"
        echo ""
        read -p "Continue? (y/n) " -n 1 -r
        echo ""
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo "Aborted."
            exit 0
        fi

        # Check if pgbench tables exist
        if ! kubectl exec -n otel-demo $POD -- psql -U root otel -c "\d pgbench_accounts" >/dev/null 2>&1; then
            echo -e "${YELLOW}pgbench tables not found. Initializing with large dataset...${NC}"
            kubectl exec -n otel-demo $POD -- pgbench -i -s 100 -U root otel
        fi

        echo -e "${BLUE}Running expensive queries for 5 minutes...${NC}"
        echo "Monitor in Honeycomb: Watch for query duration spikes"

        # Create custom pgbench script with expensive queries
        kubectl exec -n otel-demo $POD -- bash -c "cat > /tmp/slow-query.sql <<'EOSQL'
-- Full table scan with aggregation
SELECT
    COUNT(*),
    AVG(abalance),
    SUM(abalance),
    MAX(abalance),
    MIN(abalance)
FROM pgbench_accounts
WHERE abalance > 0;

-- Cross join simulation (expensive)
SELECT COUNT(*)
FROM pgbench_accounts a, pgbench_branches b
WHERE a.bid = b.bid;

-- Sort entire table
SELECT * FROM pgbench_accounts ORDER BY abalance DESC LIMIT 1000;
EOSQL
"

        kubectl exec -n otel-demo $POD -- pgbench \
            -c 20 \
            -T 300 \
            -f /tmp/slow-query.sql \
            -P 10 \
            -r \
            -U root \
            otel

        echo -e "${GREEN}Slow query test complete!${NC}"
        exit 0
        ;;
    demo)
        echo -e "${BLUE}=========================================="
        echo "  DEMO MODE: All Failure Scenarios"
        echo "==========================================${NC}"
        echo ""
        echo "This will run all three failure scenarios:"
        echo "  1. Connection Exhaustion (3 min)"
        echo "  2. Recovery pause (1 min)"
        echo "  3. Table Lock (2 min)"
        echo "  4. Recovery pause (1 min)"
        echo "  5. Slow Query (3 min)"
        echo ""
        echo "Total duration: ~10 minutes"
        echo ""
        echo "Keep your Honeycomb dashboard open to watch:"
        echo "  - accounting dataset for errors and latency"
        echo "  - Metrics dataset for CPU/memory/connections"
        echo ""
        read -p "Continue? (y/n) " -n 1 -r
        echo ""
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo "Aborted."
            exit 0
        fi

        # Ensure pgbench tables exist
        if ! kubectl exec -n otel-demo $POD -- psql -U root otel -c "\d pgbench_accounts" >/dev/null 2>&1; then
            echo -e "${YELLOW}Initializing pgbench tables...${NC}"
            kubectl exec -n otel-demo $POD -- pgbench -i -s 50 -U root otel
        fi

        echo ""
        echo -e "${RED}=========================================="
        echo "  SCENARIO 1: Connection Exhaustion"
        echo "==========================================${NC}"
        echo "Opening 95 connections for 3 minutes..."
        echo ""

        kubectl exec -n otel-demo $POD -- bash -c '
            for i in {1..95}; do
                psql -U root otel -c "SELECT pg_sleep(180), '\''Conn $i'\''" >/dev/null 2>&1 &
            done
            echo "✓ 95 connections opened"
            wait
        ' &
        CONN_PID=$!

        echo "Monitor: Look for 'too many clients' errors in accounting dataset"
        sleep 180
        wait $CONN_PID 2>/dev/null

        echo ""
        echo -e "${GREEN}✓ Connection exhaustion complete${NC}"
        echo -e "${BLUE}Waiting 60 seconds for recovery...${NC}"
        sleep 60

        echo ""
        echo -e "${RED}=========================================="
        echo "  SCENARIO 2: Table Lock"
        echo "==========================================${NC}"
        echo "Locking pgbench_accounts table for 2 minutes..."
        echo ""

        kubectl exec -n otel-demo $POD -- psql -U root otel <<'EOF' &
BEGIN;
LOCK TABLE pgbench_accounts IN ACCESS EXCLUSIVE MODE;
SELECT pg_sleep(120);
COMMIT;
EOF
        LOCK_PID=$!

        echo "Monitor: Look for query duration spikes (30+ seconds)"
        sleep 120
        wait $LOCK_PID 2>/dev/null

        echo ""
        echo -e "${GREEN}✓ Table lock complete${NC}"
        echo -e "${BLUE}Waiting 60 seconds for recovery...${NC}"
        sleep 60

        echo ""
        echo -e "${RED}=========================================="
        echo "  SCENARIO 3: Slow Query"
        echo "==========================================${NC}"
        echo "Running expensive queries for 3 minutes..."
        echo ""

        kubectl exec -n otel-demo $POD -- bash -c "cat > /tmp/demo-slow-query.sql <<'EOSQL'
SELECT COUNT(*), AVG(abalance), SUM(abalance)
FROM pgbench_accounts
WHERE abalance > 0;

SELECT COUNT(*)
FROM pgbench_accounts a, pgbench_branches b
WHERE a.bid = b.bid;
EOSQL
"

        kubectl exec -n otel-demo $POD -- pgbench \
            -c 15 \
            -T 180 \
            -f /tmp/demo-slow-query.sql \
            -P 30 \
            -r \
            -U root \
            otel

        echo ""
        echo -e "${GREEN}=========================================="
        echo "  DEMO COMPLETE!"
        echo "==========================================${NC}"
        echo ""
        echo "Summary of what you should see in Honeycomb:"
        echo ""
        echo "1. Connection Exhaustion (T+0 to T+3):"
        echo "   ✓ Connection count → 95-100"
        echo "   ✓ Error: 'too many clients already'"
        echo "   ✓ CPU: Low (connections idle)"
        echo ""
        echo "2. Table Lock (T+4 to T+6):"
        echo "   ✓ Query duration → 30,000+ ms"
        echo "   ✓ No connection errors"
        echo "   ✓ CPU: Low (queries blocked)"
        echo ""
        echo "3. Slow Query (T+7 to T+10):"
        echo "   ✓ Query duration → 100-500ms"
        echo "   ✓ CPU: 80-100%"
        echo "   ✓ No errors, just slow"
        echo ""
        exit 0
        ;;
    *)
        echo -e "${RED}Error: Unknown scenario '${LOAD_LEVEL}'${NC}"
        echo "Usage: $0 {light|normal|beast|accounting|connection-exhaust|table-lock|slow-query|demo|init|clean|status}"
        exit 1
        ;;
esac

echo ""
read -p "Continue? (y/n) " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
fi

echo ""
echo -e "${BLUE}Initializing pgbench tables (scale=$SCALE)...${NC}"
kubectl exec -n otel-demo $POD -- pgbench -i -s $SCALE -U root otel 2>&1 | tail -5

echo ""
echo -e "${BLUE}Starting load test...${NC}"
echo -e "${YELLOW}Press Ctrl+C to stop (pgbench will continue running in pod)${NC}"
echo ""

# Run pgbench
kubectl exec -n otel-demo $POD -- pgbench \
    -c $CLIENTS \
    -j $(($CLIENTS / 2)) \
    -t $TRANSACTIONS \
    -P 10 \
    -r \
    -U root \
    otel

echo ""
echo -e "${GREEN}=========================================="
echo "Load test complete!"
echo -e "==========================================${NC}"
