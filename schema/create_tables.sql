-- ============================================================
-- SCHEMA: E-Commerce Analytics Database
-- Used across all SQL cookbook modules
-- PostgreSQL 14+
-- ============================================================

-- Users / customers
CREATE TABLE IF NOT EXISTS users (
    user_id         SERIAL PRIMARY KEY,
    email           TEXT UNIQUE NOT NULL,
    name            TEXT NOT NULL,
    country         TEXT NOT NULL DEFAULT 'IN',
    plan            TEXT NOT NULL DEFAULT 'free' CHECK (plan IN ('free','starter','pro','enterprise')),
    acquired_channel TEXT,                        -- organic, paid, referral, direct
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    churned_at      TIMESTAMPTZ                   -- NULL = active
);

-- Products
CREATE TABLE IF NOT EXISTS products (
    product_id      SERIAL PRIMARY KEY,
    name            TEXT NOT NULL,
    category        TEXT NOT NULL,
    subcategory     TEXT,
    price           NUMERIC(10,2) NOT NULL CHECK (price > 0),
    cost            NUMERIC(10,2) NOT NULL CHECK (cost > 0),
    launched_at     DATE NOT NULL
);

-- Orders (transactions)
CREATE TABLE IF NOT EXISTS orders (
    order_id        SERIAL PRIMARY KEY,
    user_id         INT NOT NULL REFERENCES users(user_id),
    order_date      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    status          TEXT NOT NULL DEFAULT 'completed'
                        CHECK (status IN ('pending','completed','refunded','cancelled')),
    shipping_country TEXT NOT NULL DEFAULT 'IN'
);

-- Order line items
CREATE TABLE IF NOT EXISTS order_items (
    item_id         SERIAL PRIMARY KEY,
    order_id        INT NOT NULL REFERENCES orders(order_id),
    product_id      INT NOT NULL REFERENCES products(product_id),
    quantity        INT NOT NULL CHECK (quantity > 0),
    unit_price      NUMERIC(10,2) NOT NULL,
    discount_pct    NUMERIC(5,2) NOT NULL DEFAULT 0 CHECK (discount_pct BETWEEN 0 AND 100)
);

-- Product page events (for funnel analysis)
CREATE TABLE IF NOT EXISTS events (
    event_id        BIGSERIAL PRIMARY KEY,
    user_id         INT REFERENCES users(user_id),  -- NULL = anonymous
    session_id      TEXT NOT NULL,
    event_type      TEXT NOT NULL,   -- page_view, add_to_cart, checkout_start, purchase
    product_id      INT REFERENCES products(product_id),
    event_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    device_type     TEXT,            -- mobile, desktop, tablet
    referrer        TEXT
);

-- SaaS subscriptions (for MRR/churn metrics)
CREATE TABLE IF NOT EXISTS subscriptions (
    sub_id          SERIAL PRIMARY KEY,
    user_id         INT NOT NULL REFERENCES users(user_id),
    plan            TEXT NOT NULL,
    mrr             NUMERIC(10,2) NOT NULL CHECK (mrr >= 0),
    started_at      DATE NOT NULL,
    ended_at        DATE,                         -- NULL = active
    churn_reason    TEXT
);

-- Indexes for analytics query performance
CREATE INDEX IF NOT EXISTS idx_orders_user_date    ON orders(user_id, order_date);
CREATE INDEX IF NOT EXISTS idx_orders_date         ON orders(order_date DESC);
CREATE INDEX IF NOT EXISTS idx_events_user_type    ON events(user_id, event_type);
CREATE INDEX IF NOT EXISTS idx_events_session      ON events(session_id, event_at);
CREATE INDEX IF NOT EXISTS idx_events_at           ON events(event_at DESC);
CREATE INDEX IF NOT EXISTS idx_subs_user           ON subscriptions(user_id);
CREATE INDEX IF NOT EXISTS idx_subs_dates          ON subscriptions(started_at, ended_at);

-- Computed view: revenue per order
CREATE OR REPLACE VIEW order_revenue AS
SELECT
    o.order_id,
    o.user_id,
    o.order_date,
    o.status,
    SUM(oi.quantity * oi.unit_price * (1 - oi.discount_pct / 100.0)) AS net_revenue,
    SUM(oi.quantity * p.cost)                                          AS total_cost,
    SUM(oi.quantity * oi.unit_price * (1 - oi.discount_pct / 100.0))
        - SUM(oi.quantity * p.cost)                                    AS gross_profit
FROM orders o
JOIN order_items oi USING (order_id)
JOIN products    p  USING (product_id)
WHERE o.status = 'completed'
GROUP BY o.order_id, o.user_id, o.order_date, o.status;
