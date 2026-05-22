-- ============================================================
-- MODULE 07: Query Optimisation
-- Reading EXPLAIN, indexing strategy, and rewriting slow queries
-- ============================================================

-- ════════════════════════════════════════════════════════════
-- 7.1  READING EXPLAIN ANALYZE
--      The single most important skill for SQL performance
-- ════════════════════════════════════════════════════════════

-- Run EXPLAIN ANALYZE to see the actual execution plan + timing.
-- Look for: Seq Scan (bad on large tables), high "actual time",
--           rows estimate vs actual mismatch (stale statistics).

EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
SELECT u.country, COUNT(*) AS orders, SUM(r.net_revenue) AS revenue
FROM users u
JOIN order_revenue r ON r.user_id = u.user_id
WHERE u.created_at > NOW() - INTERVAL '90 days'
GROUP BY u.country
ORDER BY revenue DESC;

-- What to look for in the output:
--   "Seq Scan on users"        → consider an index on created_at
--   "Hash Join" vs "Nested Loop" → Nested Loop bad for large sets
--   "rows=1000 ... actual rows=50000" → run ANALYZE to refresh stats
--   "Buffers: shared read=X"   → high read = data not cached


-- ════════════════════════════════════════════════════════════
-- 7.2  INDEXING STRATEGY
-- ════════════════════════════════════════════════════════════

-- Single-column index: speeds up WHERE / JOIN / ORDER BY on that column
CREATE INDEX IF NOT EXISTS idx_users_created ON users(created_at);

-- Composite index: column order matters! Put the most selective /
-- most-filtered column first. This index serves queries filtering on
-- user_id, OR (user_id AND order_date), but NOT order_date alone.
CREATE INDEX IF NOT EXISTS idx_orders_user_date ON orders(user_id, order_date DESC);

-- Partial index: index only the rows you query frequently. Smaller,
-- faster, and cheaper to maintain. Great for "active" subsets.
CREATE INDEX IF NOT EXISTS idx_active_users
    ON users(user_id) WHERE churned_at IS NULL;

-- Covering index (INCLUDE): the index itself answers the query —
-- no table lookup needed ("index-only scan").
CREATE INDEX IF NOT EXISTS idx_orders_covering
    ON orders(user_id) INCLUDE (order_date, status);

-- Expression index: for queries that filter on a computed value
CREATE INDEX IF NOT EXISTS idx_users_email_lower
    ON users(LOWER(email));

-- Refresh planner statistics after big data changes
ANALYZE orders;
ANALYZE order_items;


-- ════════════════════════════════════════════════════════════
-- 7.3  REWRITING SLOW QUERIES
-- ════════════════════════════════════════════════════════════

-- ── Anti-pattern 1: SELECT in a loop (correlated subquery per row) ──
-- SLOW: runs the subquery once per outer row
SELECT u.user_id, u.name,
    (SELECT COUNT(*) FROM orders o WHERE o.user_id = u.user_id) AS order_count
FROM users u;

-- FAST: single JOIN + GROUP BY does it in one pass
SELECT u.user_id, u.name, COUNT(o.order_id) AS order_count
FROM users u
LEFT JOIN orders o ON o.user_id = u.user_id
GROUP BY u.user_id, u.name;


-- ── Anti-pattern 2: function on indexed column kills the index ──
-- SLOW: DATE() wraps the column → index unused, full scan
-- SELECT * FROM orders WHERE DATE(order_date) = '2024-01-15';

-- FAST: range condition keeps the index usable
SELECT * FROM orders
WHERE order_date >= '2024-01-15'::DATE
  AND order_date <  '2024-01-16'::DATE;


-- ── Anti-pattern 3: OR conditions prevent index usage ──
-- SLOW: OR across different columns
-- SELECT * FROM users WHERE country = 'IN' OR plan = 'pro';

-- FAST: UNION of two index-friendly queries
SELECT * FROM users WHERE country = 'IN'
UNION
SELECT * FROM users WHERE plan = 'pro';


-- ── Anti-pattern 4: COUNT(*) on huge table for existence check ──
-- SLOW: counts every matching row
-- SELECT COUNT(*) FROM events WHERE user_id = 42;

-- FAST: EXISTS short-circuits at first match
SELECT EXISTS (SELECT 1 FROM events WHERE user_id = 42) AS has_events;


-- ════════════════════════════════════════════════════════════
-- 7.4  PAGINATION — keyset beats OFFSET at scale
-- ════════════════════════════════════════════════════════════

-- SLOW at high offsets: OFFSET 100000 still scans+discards 100k rows
-- SELECT * FROM orders ORDER BY order_id LIMIT 20 OFFSET 100000;

-- FAST keyset pagination: use last-seen id as a cursor
SELECT * FROM orders
WHERE order_id > 100000          -- last order_id from previous page
ORDER BY order_id
LIMIT 20;


-- ════════════════════════════════════════════════════════════
-- 7.5  TABLE PARTITIONING (for very large time-series tables)
-- ════════════════════════════════════════════════════════════

-- Range-partition events by month so queries touch only relevant partitions
-- CREATE TABLE events_partitioned (LIKE events INCLUDING ALL)
--     PARTITION BY RANGE (event_at);
-- CREATE TABLE events_2024_01 PARTITION OF events_partitioned
--     FOR VALUES FROM ('2024-01-01') TO ('2024-02-01');
-- Queries with WHERE event_at BETWEEN ... only scan matching partitions
-- ("partition pruning") — dramatically faster on billion-row tables.
