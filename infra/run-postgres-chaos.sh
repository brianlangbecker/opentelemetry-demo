#!/bin/bash
# Interactive PostgreSQL Chaos Script
# Applies specific chaos scenarios to demonstrate database performance issues

set -e

NAMESPACE="otel-demo"
POD=$(kubectl get pod -n $NAMESPACE -l app.kubernetes.io/name=postgresql -o jsonpath='{.items[0].metadata.name}')

if [ -z "$POD" ]; then
  echo "❌ Error: PostgreSQL pod not found in namespace $NAMESPACE"
  exit 1
fi

echo "🎭 PostgreSQL Chaos Engineering Script"
echo "Found PostgreSQL pod: $POD"
echo ""

# Function to run SQL in PostgreSQL
run_sql() {
  kubectl exec -n $NAMESPACE $POD -- psql -U root -d otel -c "$1"
}

# Function to run SQL file in PostgreSQL
run_sql_file() {
  kubectl exec -n $NAMESPACE $POD -- psql -U root -d otel -c "$1"
}

show_menu() {
  echo "========================================"
  echo "Select Chaos Scenario:"
  echo "========================================"
  echo "1. 🔒 Table Lock (30s) - Blocks all writes"
  echo "2. 🔐 Row Locks (20s) - Creates contention on 100 orders"
  echo "3. 🐌 Slow Query - Full table scan + expensive joins"
  echo "4. 💥 Bloat Generator - Creates dead tuples (10K updates)"
  echo "5. 📊 Long Analytics Query - Heavy aggregation"
  echo "12. 🔥 HEAVY MAINTENANCE (5-10 min) - Sustained chaos!"
  echo ""
  echo "6. 🔍 Show Active Locks"
  echo "7. 🚫 Show Blocked Queries"
  echo "8. 📈 Show Table Bloat"
  echo "9. ⏱️  Show Slow Queries"
  echo "10. 🧹 VACUUM FULL (clean up bloat)"
  echo "11. 📊 Show Database Stats"
  echo "0. Exit"
  echo "========================================"
}

# Scenario functions
scenario_table_lock() {
  echo "🔒 Applying Table Lock for 30 seconds..."
  echo "   This will block ALL writes to the 'order' table"
  read -p "   Continue? (y/n) " -n 1 -r
  echo
  if [[ $REPLY =~ ^[Yy]$ ]]; then
    run_sql "BEGIN; LOCK TABLE \"order\" IN EXCLUSIVE MODE; SELECT pg_sleep(30); COMMIT;"
    echo "✅ Lock released"
  fi
}

scenario_row_locks() {
  echo "🔐 Locking 100 random orders for 20 seconds..."
  echo "   This creates row-level contention"
  run_sql "BEGIN; SELECT * FROM \"order\" WHERE order_id IN (SELECT order_id FROM \"order\" ORDER BY RANDOM() LIMIT 100) FOR UPDATE; SELECT pg_sleep(20); COMMIT;"
  echo "✅ Row locks released"
}

scenario_slow_query() {
  echo "🐌 Running expensive query (full table scan + aggregation)..."
  run_sql "SELECT o.order_id, COUNT(oi.product_id) FROM \"order\" o LEFT JOIN orderitem oi ON oi.order_id = o.order_id WHERE o.order_id > '0' GROUP BY o.order_id ORDER BY COUNT(oi.product_id) DESC LIMIT 20;"
  echo "✅ Query completed"
}

scenario_bloat() {
  echo "💥 Creating bloat (updating 1000 orders 10 times each)..."
  echo "   This creates 10,000 dead tuples"
  read -p "   This will take ~30 seconds. Continue? (y/n) " -n 1 -r
  echo
  if [[ $REPLY =~ ^[Yy]$ ]]; then
    run_sql "DO \$\$ DECLARE order_rec RECORD; BEGIN FOR order_rec IN SELECT order_id FROM \"order\" ORDER BY RANDOM() LIMIT 1000 LOOP FOR i IN 1..10 LOOP UPDATE orderitem SET quantity = quantity WHERE order_id = order_rec.order_id; END LOOP; END LOOP; END \$\$;"
    echo "✅ Bloat created. Run 'Show Table Bloat' to see the damage"
  fi
}

scenario_analytics() {
  echo "📊 Running long analytics query (heavy aggregation)..."
  run_sql "SELECT s.city, s.state, COUNT(DISTINCT o.order_id) as order_count, SUM(oi.item_cost_units) as total_revenue FROM shipping s JOIN \"order\" o ON s.order_id = o.order_id JOIN orderitem oi ON oi.order_id = o.order_id WHERE s.country LIKE '%' GROUP BY s.city, s.state ORDER BY total_revenue DESC LIMIT 20;"
  echo "✅ Analytics query completed"
}

scenario_heavy_maintenance() {
  echo ""
  echo "🔥🔥🔥 HEAVY MAINTENANCE SIMULATION 🔥🔥🔥"
  echo ""
  echo "This will run for 5-10 MINUTES and cause:"
  echo "  • Table locks blocking writes"
  echo "  • Expensive queries consuming CPU"
  echo "  • Dead tuple accumulation (bloat)"
  echo "  • High disk I/O"
  echo "  • Connection slot pressure"
  echo ""
  read -p "⚠️  This is a DESTRUCTIVE scenario. Continue? (y/n) " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Cancelled."
    return
  fi
  
  echo ""
  read -p "Choose duration: (1) 5 minutes  (2) 10 minutes  (3) 20 minutes  Enter 1, 2, or 3: " -n 1 -r duration_choice
  echo
  
  if [[ $duration_choice == "1" ]]; then
    DURATION=300  # 5 minutes
    CYCLES=10     # 30 seconds per cycle
    echo "🔥 Running 5-minute maintenance simulation..."
  elif [[ $duration_choice == "2" ]]; then
    DURATION=600  # 10 minutes
    CYCLES=20     # 30 seconds per cycle
    echo "🔥 Running 10-minute maintenance simulation..."
  elif [[ $duration_choice == "3" ]]; then
    DURATION=1200 # 20 minutes
    CYCLES=40     # 30 seconds per cycle
    echo "🔥🔥 Running 20-minute EXTENDED maintenance simulation... 🔥🔥"
  else
    echo "❌ Invalid choice, defaulting to 5 minutes"
    DURATION=300
    CYCLES=10
  fi
  
  echo ""
  echo "🚀 Starting chaos at $(date '+%H:%M:%S')..."
  echo "   Press Ctrl+C to abort early"
  echo ""
  
  # Create a temporary SQL script
  CHAOS_SQL="
DO \$\$
DECLARE
  cycle INT := 0;
  start_time TIMESTAMP := clock_timestamp();
  elapsed INTERVAL;
  order_rec RECORD;
BEGIN
  RAISE NOTICE '🔥 Heavy Maintenance Simulation Started';
  RAISE NOTICE '   Duration: ${DURATION} seconds (${CYCLES} cycles)';
  RAISE NOTICE '   Start time: %', start_time;
  
  FOR cycle IN 1..$CYCLES LOOP
    elapsed := clock_timestamp() - start_time;
    RAISE NOTICE '';
    RAISE NOTICE '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━';
    RAISE NOTICE '🔥 Cycle % of % (Elapsed: %)', cycle, $CYCLES, elapsed;
    RAISE NOTICE '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━';
    
    -- Phase 1: Table Lock (5 seconds)
    RAISE NOTICE '  🔒 Phase 1: Acquiring exclusive lock on order table...';
    BEGIN
      LOCK TABLE \"order\" IN EXCLUSIVE MODE NOWAIT;
      RAISE NOTICE '     ✓ Lock acquired, holding for 5 seconds...';
      PERFORM pg_sleep(5);
      COMMIT;
    EXCEPTION
      WHEN lock_not_available THEN
        RAISE NOTICE '     ⚠ Lock not available, skipping...';
    END;
    
    -- Phase 2: Bloat Generation (10 seconds)
    RAISE NOTICE '  💥 Phase 2: Creating dead tuples (bloat)...';
    FOR order_rec IN 
      SELECT order_id FROM \"order\" ORDER BY RANDOM() LIMIT 200
    LOOP
      UPDATE orderitem SET quantity = quantity WHERE order_id = order_rec.order_id;
    END LOOP;
    RAISE NOTICE '     ✓ Created ~600 dead tuples';
    
    -- Phase 3: Expensive Query (10 seconds)
    RAISE NOTICE '  🐌 Phase 3: Running expensive aggregation...';
    PERFORM COUNT(*) FROM (
      SELECT o.order_id, COUNT(oi.product_id)
      FROM \"order\" o
      LEFT JOIN orderitem oi ON oi.order_id = o.order_id
      WHERE o.order_id > '0'
      GROUP BY o.order_id
    ) AS subquery;
    RAISE NOTICE '     ✓ Query completed';
    
    -- Phase 4: Row-Level Contention (5 seconds)
    RAISE NOTICE '  🔐 Phase 4: Creating row-level locks...';
    BEGIN
      FOR order_rec IN 
        SELECT order_id FROM \"order\" ORDER BY RANDOM() LIMIT 50 FOR UPDATE NOWAIT
      LOOP
        NULL;  -- Just hold the locks
      END LOOP;
      PERFORM pg_sleep(3);
      COMMIT;
    EXCEPTION
      WHEN lock_not_available THEN
        RAISE NOTICE '     ⚠ Some rows already locked';
    END;
    
    RAISE NOTICE '  ✓ Cycle % completed', cycle;
    RAISE NOTICE '';
  END LOOP;
  
  elapsed := clock_timestamp() - start_time;
  RAISE NOTICE '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━';
  RAISE NOTICE '✅ HEAVY MAINTENANCE COMPLETE';
  RAISE NOTICE '   Total time: %', elapsed;
  RAISE NOTICE '   Cycles: %', $CYCLES;
  RAISE NOTICE '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━';
END \$\$;
"
  
  # Run the chaos
  kubectl exec -n $NAMESPACE $POD -- psql -U root -d otel -c "$CHAOS_SQL"
  
  echo ""
  echo "✅ Heavy maintenance simulation completed at $(date '+%H:%M:%S')"
  echo ""
  echo "📊 Recommended: Run option 8 (Show Table Bloat) to see the damage"
}

show_locks() {
  echo "🔍 Active Locks:"
  run_sql "SELECT l.pid, l.mode, l.granted, LEFT(a.query, 60) as query, a.state, now() - a.query_start as duration FROM pg_locks l JOIN pg_stat_activity a ON l.pid = a.pid WHERE a.datname = 'otel' ORDER BY duration DESC LIMIT 20;"
}

show_blocked() {
  echo "🚫 Blocked Queries:"
  run_sql "SELECT blocked.pid AS blocked_pid, LEFT(blocked.query, 40) AS blocked_query, blocker.pid AS blocker_pid, now() - blocked.query_start AS blocked_duration FROM pg_stat_activity blocked JOIN pg_locks blocked_locks ON blocked.pid = blocked_locks.pid JOIN pg_locks blocker_locks ON blocked_locks.relation = blocker_locks.relation AND blocked_locks.pid != blocker_locks.pid JOIN pg_stat_activity blocker ON blocker_locks.pid = blocker.pid WHERE NOT blocked_locks.granted AND blocked.datname = 'otel';"
}

show_bloat() {
  echo "📈 Table Bloat:"
  run_sql "SELECT relname AS table, pg_size_pretty(pg_total_relation_size('public.'||relname)) AS size, n_dead_tup AS dead, n_live_tup AS live, CASE WHEN n_live_tup > 0 THEN round(100.0 * n_dead_tup / (n_live_tup + n_dead_tup), 2) ELSE 0 END AS bloat_pct FROM pg_stat_user_tables WHERE schemaname = 'public' ORDER BY n_dead_tup DESC;"
}

show_slow_queries() {
  echo "⏱️  Slow Queries (running > 5 seconds):"
  run_sql "SELECT pid, now() - query_start AS duration, state, wait_event_type, wait_event, LEFT(query, 80) AS query FROM pg_stat_activity WHERE datname = 'otel' AND state != 'idle' AND query_start < now() - interval '5 seconds' ORDER BY duration DESC;"
}

vacuum_full() {
  echo "🧹 Running VACUUM FULL..."
  echo "   This will clean up dead tuples and reclaim space"
  read -p "   This may take a while and will lock tables. Continue? (y/n) " -n 1 -r
  echo
  if [[ $REPLY =~ ^[Yy]$ ]]; then
    run_sql "VACUUM FULL;"
    echo "✅ VACUUM FULL completed"
  fi
}

show_db_stats() {
  echo "📊 Database Statistics:"
  run_sql "SELECT pg_size_pretty(pg_database_size('otel')) as db_size, (SELECT COUNT(*) FROM \"order\") as orders, (SELECT COUNT(*) FROM orderitem) as items, (SELECT COUNT(*) FROM shipping) as shipping;"
  echo ""
  run_sql "SHOW shared_buffers;"
  echo ""
  run_sql "SELECT datname, blks_read, blks_hit, CASE WHEN blks_hit + blks_read = 0 THEN 0 ELSE round(100.0 * blks_hit / (blks_hit + blks_read), 2) END as cache_hit_ratio FROM pg_stat_database WHERE datname = 'otel';"
}

# Main loop
while true; do
  echo ""
  show_menu
  read -p "Enter choice: " choice
  echo ""
  
  case $choice in
    1) scenario_table_lock ;;
    2) scenario_row_locks ;;
    3) scenario_slow_query ;;
    4) scenario_bloat ;;
    5) scenario_analytics ;;
    12) scenario_heavy_maintenance ;;
    6) show_locks ;;
    7) show_blocked ;;
    8) show_bloat ;;
    9) show_slow_queries ;;
    10) vacuum_full ;;
    11) show_db_stats ;;
    0) echo "👋 Exiting chaos script"; exit 0 ;;
    *) echo "❌ Invalid choice" ;;
  esac
  
  echo ""
  read -p "Press Enter to continue..."
done

