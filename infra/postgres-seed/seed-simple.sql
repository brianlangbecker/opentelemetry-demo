-- Simple seed: 150k orders
INSERT INTO "order" (order_id)
SELECT gen_random_uuid()::TEXT
FROM generate_series(1, 150000);

-- Add 3 items per order
INSERT INTO orderitem (
    item_cost_currency_code,
    item_cost_units,
    item_cost_nanos,
    product_id,
    quantity,
    order_id
)
SELECT
    'USD',
    floor(random() * 100 + 10)::BIGINT,
    floor(random() * 1000000000)::INT,
    (ARRAY['OLJCESPC7Z','66VCHSJNUP','1YMWWN1N4O','L9ECAV7KIM','2ZYFJ3GM2N'])[floor(random() * 5 + 1)::INTEGER],
    floor(random() * 5 + 1)::INT,
    o.order_id
FROM "order" o
CROSS JOIN generate_series(1, 3)
ON CONFLICT DO NOTHING;

-- Add shipping for each order
INSERT INTO shipping (
    shipping_tracking_id,
    shipping_cost_currency_code,
    shipping_cost_units,
    shipping_cost_nanos,
    street_address,
    city,
    state,
    country,
    zip_code,
    order_id
)
SELECT
    gen_random_uuid()::TEXT,
    'USD',
    floor(random() * 20 + 5)::BIGINT,
    floor(random() * 1000000000)::INT,
    floor(random() * 9999 + 1)::TEXT || ' Main St',
    (ARRAY['New York','Los Angeles','Chicago','Houston','Phoenix'])[floor(random() * 5 + 1)::INTEGER],
    (ARRAY['NY','CA','IL','TX','AZ'])[floor(random() * 5 + 1)::INTEGER],
    'USA',
    lpad(floor(random() * 99999)::TEXT, 5, '0'),
    o.order_id
FROM "order" o;

SELECT COUNT(*) as total_orders, pg_size_pretty(pg_database_size('otel')) as db_size FROM "order";

