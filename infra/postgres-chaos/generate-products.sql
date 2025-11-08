-- Generate 1000 Products for OpenTelemetry Demo Product Catalog
-- This script creates astronomy/telescope themed products following the existing schema
-- Usage: psql -U root -d otel -f generate-products.sql

-- Function to generate random product ID (10 uppercase alphanumeric characters)
CREATE OR REPLACE FUNCTION generate_product_id() RETURNS TEXT AS $$
DECLARE
    chars TEXT := 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    result TEXT := '';
    i INTEGER;
BEGIN
    FOR i IN 1..10 LOOP
        result := result || substr(chars, floor(random() * length(chars) + 1)::int, 1);
    END LOOP;
    RETURN result;
END;
$$ LANGUAGE plpgsql;

-- Product name templates
CREATE TEMP TABLE product_prefixes AS VALUES
    ('Advanced'), ('Professional'), ('Beginner'), ('Premium'), ('Compact'),
    ('Portable'), ('Deluxe'), ('Elite'), ('Pro'), ('Digital'),
    ('Smart'), ('Automatic'), ('Manual'), ('High-Power'), ('Ultra'),
    ('Standard'), ('Classic'), ('Modern'), ('Vintage'), ('Explorer'),
    ('Discovery'), ('Celestial'), ('Stellar'), ('Cosmic'), ('Lunar'),
    ('Solar'), ('Planetary'), ('Deep Sky'), ('Observatory'), ('Astro');

CREATE TEMP TABLE product_types AS VALUES
    ('Refractor Telescope'), ('Reflector Telescope'), ('Dobsonian Telescope'),
    ('Catadioptric Telescope'), ('Binoculars'), ('Spotting Scope'),
    ('Eyepiece'), ('Barlow Lens'), ('Filter Set'), ('Mount'),
    ('Tripod'), ('Finder Scope'), ('Red Dot Finder'), ('Star Chart'),
    ('Astronomy Book'), ('Sky Atlas'), ('Planisphere'), ('Telescope Case'),
    ('Collimation Tool'), ('Laser Pointer'), ('Dew Shield'), ('Camera Adapter'),
    ('T-Ring'), ('Flashlight'), ('Observing Chair'), ('Power Supply'),
    ('Battery Pack'), ('Cleaning Kit'), ('Carrying Bag'), ('Solar Filter');

CREATE TEMP TABLE product_suffixes AS VALUES
    ('Pro'), ('Plus'), ('Max'), ('Ultra'), ('SE'), ('DX'), ('XL'),
    ('Lite'), ('Mini'), ('Mega'), ('Edition'), ('Series'), ('Model'),
    ('Kit'), ('Set'), ('Bundle'), ('Package'), ('System'), ('V2'), ('V3');

-- Category options
CREATE TEMP TABLE category_options AS VALUES
    ('telescopes'), ('binoculars'), ('accessories'), ('books'),
    ('flashlights'), ('travel'), ('assembly'), ('cameras'),
    ('mounts'), ('filters'), ('eyepieces'), ('cases');

-- Real product images that exist in the frontend
CREATE TEMP TABLE real_images AS VALUES
    ('EclipsmartTravelRefractorTelescope.jpg'),
    ('LensCleaningKit.jpg'),
    ('NationalParkFoundationExplorascope.jpg'),
    ('OpticalTubeAssembly.jpg'),
    ('RedFlashlight.jpg'),
    ('RoofBinoculars.jpg'),
    ('SolarFilter.jpg'),
    ('SolarSystemColorImager.jpg'),
    ('StarsenseExplorer.jpg'),
    ('TheCometBook.jpg');

-- Add row numbers to images for round-robin selection
CREATE TEMP TABLE numbered_images AS
SELECT row_number() OVER () - 1 as img_num, column1 as picture
FROM real_images;

-- Generate 1000 products
INSERT INTO products (
    id,
    name,
    description,
    picture,
    price_currency_code,
    price_units,
    price_nanos,
    categories
)
SELECT
    generate_product_id() AS id,
    -- Generate product name from templates
    (SELECT column1 FROM product_prefixes ORDER BY random() LIMIT 1) || ' ' ||
    (SELECT column1 FROM product_types ORDER BY random() LIMIT 1) || ' ' ||
    (SELECT column1 FROM product_suffixes ORDER BY random() LIMIT 1) AS name,
    -- Generate description
    'A high-quality astronomy product designed for both amateur and professional astronomers. ' ||
    'Features include precision optics, durable construction, and ease of use. ' ||
    'Perfect for observing planets, moon, star clusters, nebulae, and galaxies. ' ||
    'Includes mounting hardware and detailed instruction manual. ' ||
    'Ideal for backyard astronomy, astrophotography, and educational purposes.' AS description,
    -- Use real product images in round-robin fashion
    (SELECT picture FROM numbered_images WHERE img_num = ((i - 1) % 10)) AS picture,
    -- All products in USD
    'USD' AS price_currency_code,
    -- Random price between $25 and $999
    floor(random() * 975 + 25)::bigint AS price_units,
    -- Random cents in nanoseconds (0-99 cents)
    floor(random() * 100)::integer * 10000000 AS price_nanos,
    -- Random 1-3 categories
    ARRAY(
        SELECT column1
        FROM category_options
        ORDER BY random()
        LIMIT floor(random() * 3 + 1)::integer
    ) AS categories
FROM generate_series(1, 1500) AS i;

-- Clean up temporary tables
DROP TABLE product_prefixes;
DROP TABLE product_types;
DROP TABLE product_suffixes;
DROP TABLE category_options;
DROP TABLE real_images;
DROP TABLE numbered_images;

-- Drop the helper function
DROP FUNCTION generate_product_id();

-- Update statistics after bulk insert
ANALYZE products;

-- Display summary
SELECT
    'Products inserted successfully!' as status,
    count(*) as total_products,
    min(price_units) as min_price,
    max(price_units) as max_price,
    round(avg(price_units)::numeric, 2) as avg_price
FROM products;

-- Show category distribution
SELECT
    unnest(categories) as category,
    count(*) as product_count
FROM products
GROUP BY category
ORDER BY product_count DESC;
