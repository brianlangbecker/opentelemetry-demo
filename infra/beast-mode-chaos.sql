-- BEAST MODE CHAOS - Pure UPDATE Bloat
-- Creates massive dead tuples through heavy UPDATEs

SET client_min_messages TO NOTICE;

DO $$
DECLARE
  cycle INT;
  start_time TIMESTAMP := clock_timestamp();
  dead_tuples BIGINT;
  live_tuples BIGINT;
  table_size TEXT;
  bloat_pct NUMERIC;
BEGIN
  RAISE NOTICE '==========================================';
  RAISE NOTICE 'BEAST MODE CHAOS - STARTING';
  RAISE NOTICE 'This will create REAL database chaos:';
  RAISE NOTICE '  - Massive UPDATE bloat (dead tuples)';
  RAISE NOTICE '  - Heavy queries (cache misses)';
  RAISE NOTICE '  - Lock contention';
  RAISE NOTICE '  - Disk I/O pressure';
  RAISE NOTICE 'Duration: 900 cycles × 2s = 30 minutes';
  RAISE NOTICE '==========================================';
  RAISE NOTICE '';

  FOR cycle IN 1..900 LOOP

    -- 1. UPDATE bloat - creates 500-1500 dead tuples per cycle
    UPDATE orderitem
    SET quantity = quantity + 1
    WHERE order_id IN (
      SELECT order_id
      FROM "order"
      ORDER BY RANDOM()
      LIMIT 500
    );

    -- 2. Heavy JOIN query - forces cache misses and disk I/O
    PERFORM COUNT(*)
    FROM (
      SELECT
        o.order_id,
        s.city,
        s.state,
        oi.product_id,
        oi.quantity
      FROM "order" o
      LEFT JOIN shipping s ON s.order_id = o.order_id
      LEFT JOIN orderitem oi ON oi.order_id = o.order_id
      ORDER BY RANDOM()
      LIMIT 50000
    ) AS chaos_query;

    -- 3. Big aggregation - causes temp file spills
    IF cycle % 5 = 0 THEN
      PERFORM product_id, COUNT(*), SUM(quantity), AVG(quantity), MAX(quantity), MIN(quantity)
      FROM orderitem
      GROUP BY product_id
      ORDER BY COUNT(*) DESC, SUM(quantity) DESC;
    END IF;

    -- Progress every 100 cycles (~3.3 minutes)
    IF cycle % 100 = 1 OR cycle = 900 THEN
      -- Get REAL dead tuple count
      SELECT
        n_dead_tup,
        n_live_tup,
        pg_size_pretty(pg_total_relation_size('orderitem'))
      INTO dead_tuples, live_tuples, table_size
      FROM pg_stat_user_tables
      WHERE relname = 'orderitem';

      bloat_pct := CASE
        WHEN live_tuples > 0 THEN (dead_tuples::NUMERIC / live_tuples::NUMERIC * 100)
        ELSE 0
      END;

      RAISE NOTICE '[%] Cycle %/900 | Dead: % | Bloat: % | Table: % | Elapsed: %s',
        to_char(clock_timestamp(), 'HH24:MI:SS'),
        cycle,
        dead_tuples,
        round(bloat_pct, 1) || '%',
        table_size,
        extract(epoch from (clock_timestamp() - start_time))::INT;
    END IF;

    -- Big progress every 300 cycles (~10 minutes)
    IF cycle % 300 = 0 THEN
      RAISE NOTICE '';
      RAISE NOTICE '========== % complete ==========', round(cycle::numeric / 900.0 * 100);
      RAISE NOTICE 'Real dead tuples: %', dead_tuples;
      RAISE NOTICE 'Bloat percentage: %', round(bloat_pct, 1) || '%';
      RAISE NOTICE 'Table size: %', table_size;
      RAISE NOTICE '';
    END IF;

    PERFORM pg_sleep(2);
  END LOOP;

  -- Final stats
  SELECT
    n_dead_tup,
    n_live_tup,
    pg_size_pretty(pg_total_relation_size('orderitem'))
  INTO dead_tuples, live_tuples, table_size
  FROM pg_stat_user_tables
  WHERE relname = 'orderitem';

  bloat_pct := CASE
    WHEN live_tuples > 0 THEN (dead_tuples::NUMERIC / live_tuples::NUMERIC * 100)
    ELSE 0
  END;

  RAISE NOTICE '';
  RAISE NOTICE '==========================================';
  RAISE NOTICE 'BEAST MODE COMPLETE!';
  RAISE NOTICE 'Final dead tuples: %', dead_tuples;
  RAISE NOTICE 'Final bloat: %', round(bloat_pct, 1) || '%';
  RAISE NOTICE 'Final table size: %', table_size;
  RAISE NOTICE 'Total time: % seconds', extract(epoch from (clock_timestamp() - start_time))::INT;
  RAISE NOTICE '==========================================';
  RAISE NOTICE '';
  RAISE NOTICE 'Cleanup: VACUUM FULL ANALYZE orderitem;';
END $$;
