-- ============================================================
-- SAMPLE DATA for the analytics cookbook
-- Generates realistic data using PostgreSQL generate_series + random()
-- Run AFTER create_tables.sql
-- ============================================================

-- Clear existing data (safe re-run)
TRUNCATE order_items, orders, events, subscriptions, products, users RESTART IDENTITY CASCADE;

-- ── Users: 5,000 users acquired over 2 years ──────────────────────────────────
INSERT INTO users (email, name, country, plan, acquired_channel, created_at, churned_at)
SELECT
    'user' || g || '@example.com',
    'User ' || g,
    (ARRAY['IN','US','UK','DE','SG'])[1 + floor(random() * 5)],
    (ARRAY['free','starter','pro','enterprise'])[1 + floor(random() * 4)],
    (ARRAY['organic','paid','referral','direct'])[1 + floor(random() * 4)],
    -- Acquisition spread over 730 days
    NOW() - (random() * 730 || ' days')::INTERVAL,
    -- ~20% have churned
    CASE WHEN random() < 0.20
         THEN NOW() - (random() * 200 || ' days')::INTERVAL
         ELSE NULL END
FROM generate_series(1, 5000) g;

-- ── Products: 80 products across 5 categories ─────────────────────────────────
INSERT INTO products (name, category, subcategory, price, cost, launched_at)
SELECT
    'Product ' || g,
    (ARRAY['Electronics','Apparel','Home','Sports','Grocery'])[1 + floor(random() * 5)],
    'Sub-' || (1 + floor(random() * 3)),
    ROUND((50 + random() * 4950)::NUMERIC, 2),                 -- price 50–5000
    ROUND((30 + random() * 2000)::NUMERIC, 2),                 -- cost
    (DATE '2022-01-01' + (random() * 800)::INT)
FROM generate_series(1, 80) g;

-- ── Orders: ~25,000 orders ────────────────────────────────────────────────────
INSERT INTO orders (user_id, order_date, status, shipping_country)
SELECT
    1 + floor(random() * 5000),
    NOW() - (random() * 700 || ' days')::INTERVAL,
    (ARRAY['completed','completed','completed','completed','refunded','cancelled'])[1 + floor(random() * 6)],
    (ARRAY['IN','US','UK','DE','SG'])[1 + floor(random() * 5)]
FROM generate_series(1, 25000) g;

-- ── Order items: 1–4 items per order ──────────────────────────────────────────
INSERT INTO order_items (order_id, product_id, quantity, unit_price, discount_pct)
SELECT
    o.order_id,
    1 + floor(random() * 80),
    1 + floor(random() * 4),
    ROUND((50 + random() * 4950)::NUMERIC, 2),
    ROUND((random() * 30)::NUMERIC, 2)
FROM orders o
CROSS JOIN generate_series(1, 1 + floor(random() * 3)::INT) gs;

-- ── Events: ~150,000 funnel events ────────────────────────────────────────────
INSERT INTO events (user_id, session_id, event_type, product_id, event_at, device_type, referrer)
SELECT
    CASE WHEN random() < 0.8 THEN 1 + floor(random() * 5000) ELSE NULL END,
    'sess_' || floor(random() * 40000),
    -- Funnel: most page_views, fewer carts, fewer checkouts, fewest purchases
    (ARRAY['page_view','page_view','page_view','page_view','page_view',
           'add_to_cart','add_to_cart','checkout_start','purchase'])[1 + floor(random() * 9)],
    1 + floor(random() * 80),
    NOW() - (random() * 365 || ' days')::INTERVAL,
    (ARRAY['mobile','mobile','desktop','tablet'])[1 + floor(random() * 4)],
    (ARRAY['google','direct','facebook','email','referral'])[1 + floor(random() * 5)]
FROM generate_series(1, 150000) g;

-- ── Subscriptions: 3,000 subscription records ─────────────────────────────────
INSERT INTO subscriptions (user_id, plan, mrr, started_at, ended_at, churn_reason)
SELECT
    1 + floor(random() * 5000),
    (ARRAY['starter','pro','enterprise'])[1 + floor(random() * 3)],
    ROUND((ARRAY[499, 1999, 4999])[1 + floor(random() * 3)]::NUMERIC, 2),
    (DATE '2023-01-01' + (random() * 500)::INT),
    CASE WHEN random() < 0.25
         THEN (DATE '2023-06-01' + (random() * 300)::INT)
         ELSE NULL END,
    CASE WHEN random() < 0.25
         THEN (ARRAY['too_expensive','missing_features','switched_competitor','no_longer_needed'])[1 + floor(random() * 4)]
         ELSE NULL END
FROM generate_series(1, 3000) g;

-- ── Verify ────────────────────────────────────────────────────────────────────
SELECT 'users' AS tbl, COUNT(*) FROM users
UNION ALL SELECT 'products', COUNT(*) FROM products
UNION ALL SELECT 'orders', COUNT(*) FROM orders
UNION ALL SELECT 'order_items', COUNT(*) FROM order_items
UNION ALL SELECT 'events', COUNT(*) FROM events
UNION ALL SELECT 'subscriptions', COUNT(*) FROM subscriptions;
