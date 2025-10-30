-- PostgreSQL Chaos Queries
-- Creates locks, slow queries, and inefficient operations for observability demos
-- 
-- Usage:
--   kubectl exec -n otel-demo <postgres-pod> -- psql -U root -d otel -f /tmp/postgres-chaos-queries.sql
--
-- WARNING: This will cause performance degradation! Use in demo environments only.

-- ============================================================================
-- CHAOS SCENARIO 1: Table Locks (Blocks all writes)
-- ============================================================================

-- Start a long-running transaction that holds an EXCLUSIVE lock
-- This simulates a stuck migration or maintenance operation
BEGIN;
LOCK TABLE "order" IN EXCLUSIVE MODE;
SELECT pg_sleep(30); -- Holds lock for 30 seconds
COMMIT;

-- ============================================================================
-- CHAOS SCENARIO 2: Row-Level Locks (Creates contention)
-- ============================================================================

-- Lock random orders (simulates concurrent processing conflicts)
BEGIN;
SELECT * FROM "order" 
WHERE order_id IN (
  SELECT order_id FROM "order" 
  ORDER BY RANDOM() 
  LIMIT 100
) FOR UPDATE;
SELECT pg_sleep(20); -- Hold locks for 20 seconds
COMMIT;

-- ============================================================================
-- CHAOS SCENARIO 3: Expensive Queries (CPU/Memory intensive)
-- ============================================================================

-- Full table scan without indexes (very slow)
SELECT o.order_id, COUNT(oi.product_id)
FROM "order" o
LEFT JOIN orderitem oi ON oi.order_id = o.order_id
WHERE o.order_id > '0' -- Forces sequential scan
GROUP BY o.order_id
ORDER BY COUNT(oi.product_id) DESC;

-- Cartesian product (exponential growth)
SELECT COUNT(*)
FROM "order" o1, "order" o2
WHERE o1.order_id > o2.order_id
LIMIT 1000;

-- Expensive aggregation without proper indexing
SELECT 
  s.city,
  s.state,
  COUNT(DISTINCT o.order_id) as order_count,
  SUM(oi.item_cost_units) as total_revenue
FROM shipping s
JOIN "order" o ON s.order_id = o.order_id
JOIN orderitem oi ON oi.order_id = o.order_id
WHERE s.country LIKE '%' -- Forces full scan
GROUP BY s.city, s.state
ORDER BY total_revenue DESC;

-- ============================================================================
-- CHAOS SCENARIO 4: Dead Tuple Accumulation (Causes bloat)
-- ============================================================================

-- Update same rows repeatedly (creates dead tuples without VACUUM)
DO $$
DECLARE
  order_rec RECORD;
BEGIN
  -- Update 1000 random orders 10 times each
  FOR order_rec IN 
    SELECT order_id FROM "order" ORDER BY RANDOM() LIMIT 1000
  LOOP
    FOR i IN 1..10 LOOP
      -- Dummy update that creates dead tuples
      UPDATE orderitem 
      SET quantity = quantity 
      WHERE order_id = order_rec.order_id;
    END LOOP;
  END LOOP;
END $$;

-- ============================================================================
-- CHAOS SCENARIO 5: Index Corruption Simulation (Disables indexes)
-- ============================================================================

-- Drop indexes to force sequential scans
-- Note: This won't drop primary key indexes (order_pkey, etc.)
-- But will slow down queries significantly

-- First, check existing indexes
SELECT 
  schemaname,
  tablename,
  indexname
FROM pg_indexes
WHERE schemaname = 'public'
AND indexname NOT LIKE '%pkey%'; -- Don't show primary keys

-- To actually drop indexes (commented out for safety):
-- DROP INDEX IF EXISTS idx_shipping_order_id;
-- DROP INDEX IF EXISTS idx_orderitem_order_id;

-- ============================================================================
-- CHAOS SCENARIO 6: Long-Running Analytics Query
-- ============================================================================

-- Simulates a runaway analytics query
SELECT 
  o.order_id,
  s.city,
  s.state,
  s.country,
  COUNT(oi.product_id) as item_count,
  STRING_AGG(oi.product_id, ',') as products,
  AVG(oi.item_cost_units::FLOAT) as avg_item_cost,
  SUM(oi.quantity) as total_quantity
FROM "order" o
JOIN shipping s ON s.order_id = o.order_id
JOIN orderitem oi ON oi.order_id = o.order_id
GROUP BY o.order_id, s.city, s.state, s.country
HAVING COUNT(oi.product_id) > 0
ORDER BY total_quantity DESC, avg_item_cost DESC;

-- ============================================================================
-- CHAOS SCENARIO 7: Connection Exhaustion Simulation
-- ============================================================================

-- Create many idle transactions (uses up connection slots)
-- Run this in a loop from multiple sessions:
-- 
-- DO $$
-- BEGIN
--   BEGIN; -- Start transaction
--   SELECT * FROM "order" LIMIT 1;
--   PERFORM pg_sleep(300); -- Hold connection for 5 minutes
--   COMMIT;
-- END $$;

-- ============================================================================
-- CHAOS SCENARIO 8: Statistics Invalidation
-- ============================================================================

-- Make the query planner choose bad plans by invalidating statistics
-- This forces PostgreSQL to make poor decisions

-- Reset statistics (requires superuser)
-- SELECT pg_stat_reset();

-- Delete planner statistics
-- ANALYZE only the smallest table (unbalanced stats)
ANALYZE "order";
-- Intentionally skip ANALYZE on orderitem and shipping

-- ============================================================================
-- MONITORING QUERIES - Use these to observe the chaos
-- ============================================================================

-- Show active locks
SELECT 
  l.pid,
  l.mode,
  l.granted,
  a.query,
  a.state,
  now() - a.query_start as duration
FROM pg_locks l
JOIN pg_stat_activity a ON l.pid = a.pid
WHERE a.datname = 'otel'
ORDER BY duration DESC;

-- Show blocked queries
SELECT 
  blocked.pid AS blocked_pid,
  blocked.query AS blocked_query,
  blocker.pid AS blocker_pid,
  blocker.query AS blocker_query,
  now() - blocked.query_start AS blocked_duration
FROM pg_stat_activity blocked
JOIN pg_locks blocked_locks ON blocked.pid = blocked_locks.pid
JOIN pg_locks blocker_locks ON blocked_locks.relation = blocker_locks.relation
  AND blocked_locks.pid != blocker_locks.pid
JOIN pg_stat_activity blocker ON blocker_locks.pid = blocker.pid
WHERE NOT blocked_locks.granted
  AND blocked.datname = 'otel';

-- Show table bloat
SELECT 
  schemaname,
  relname AS tablename,
  pg_size_pretty(pg_total_relation_size(schemaname||'.'||relname)) AS total_size,
  pg_size_pretty(pg_relation_size(schemaname||'.'||relname)) AS table_size,
  n_dead_tup AS dead_tuples,
  n_live_tup AS live_tuples,
  CASE 
    WHEN n_live_tup > 0 
    THEN round(100.0 * n_dead_tup / (n_live_tup + n_dead_tup), 2) 
    ELSE 0 
  END AS bloat_percentage
FROM pg_stat_user_tables
WHERE schemaname = 'public'
ORDER BY n_dead_tup DESC;

-- Show slow queries in progress
SELECT 
  pid,
  now() - query_start AS duration,
  state,
  wait_event_type,
  wait_event,
  LEFT(query, 100) AS query_preview
FROM pg_stat_activity
WHERE datname = 'otel'
  AND state != 'idle'
  AND query_start < now() - interval '5 seconds'
ORDER BY duration DESC;

