-- Custom pgbench workload targeting accounting service tables
-- This creates direct contention with the accounting service on the SAME tables
--
-- Usage: pgbench -c 50 -t 10000 -f accounting-load.sql -U root otel

-- Set random values
\set product_id random(1, 10)
\set units random(10, 1000)
\set nanos random(0, 999999999)
\set quantity random(1, 10)

-- Transaction 1: Insert new order (like accounting service does when processing Kafka messages)
BEGIN;
INSERT INTO "order" (order_id) VALUES ('load-test-' || :client_id || '-' || :scale || '-' || :units) ON CONFLICT (order_id) DO NOTHING;
INSERT INTO orderitem (order_id, product_id, item_cost_currency_code, item_cost_units, item_cost_nanos, quantity)
VALUES ('load-test-' || :client_id || '-' || :scale || '-' || :units, 'PRODUCT-' || :product_id, 'USD', :units, :nanos, :quantity)
ON CONFLICT (order_id, product_id) DO UPDATE SET quantity = orderitem.quantity + :quantity;
COMMIT;

-- Transaction 2: Query orders (like accounting service does for reporting)
SELECT COUNT(*) FROM "order" WHERE order_id LIKE 'load-test-%';
SELECT SUM(item_cost_units) FROM orderitem WHERE order_id LIKE 'load-test-%';
