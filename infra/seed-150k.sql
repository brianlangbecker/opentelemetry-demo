-- Seed 150,000 orders optimized for cache pressure demo
-- Target: ~165 MB database with 64MB shared_buffers = visible IOPS pressure

DO $$
DECLARE
    batch_size INTEGER := 5000;
    total_orders INTEGER := 150000;
    batches INTEGER := total_orders / batch_size;
    batch INTEGER;
BEGIN
    FOR batch IN 0..(batches - 1) LOOP
        -- Bulk insert orders
        INSERT INTO "order" (order_id)
        SELECT gen_random_uuid()::TEXT
        FROM generate_series(1, batch_size);
        
        -- Bulk insert order items (3 per order)
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
        WHERE o.order_id IN (
            SELECT order_id FROM "order"
            ORDER BY order_id DESC
            LIMIT batch_size
        )
        ON CONFLICT DO NOTHING;
        
        -- Bulk insert shipping
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
        FROM "order" o
        WHERE o.order_id IN (
            SELECT order_id FROM "order"
            ORDER BY order_id DESC
            LIMIT batch_size
        );
        
        IF batch % 5 = 0 THEN
            RAISE NOTICE 'Seeded % orders...', (batch + 1) * batch_size;
        END IF;
    END LOOP;
    
    RAISE NOTICE 'Seed complete! % orders ready.', total_orders;
END $$;

