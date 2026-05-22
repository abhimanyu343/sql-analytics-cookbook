-- ============================================================
-- MODULE 06: Advanced CTEs — Recursive, Lateral, Deduplication
-- ============================================================

-- ════════════════════════════════════════════════════════════
-- 6.1  RECURSIVE CTE — Date series gap filling
--      Generate every day in a range and fill missing revenue
-- ════════════════════════════════════════════════════════════

-- Without GENERATE_SERIES (pure SQL recursive, works on any DB)
WITH RECURSIVE date_series AS (
    -- Base case: start date
    SELECT MIN(order_date)::DATE AS day
    FROM order_revenue

    UNION ALL

    -- Recursive case: add one day until we reach today
    SELECT day + 1
    FROM date_series
    WHERE day < CURRENT_DATE
)
SELECT
    ds.day,
    COALESCE(SUM(r.net_revenue), 0) AS daily_revenue,
    COUNT(r.order_id)               AS order_count,
    -- Flag days with no orders (useful for anomaly detection)
    CASE WHEN SUM(r.net_revenue) IS NULL THEN TRUE ELSE FALSE END AS is_zero_day
FROM date_series ds
LEFT JOIN order_revenue r ON r.order_date::DATE = ds.day
GROUP BY ds.day
ORDER BY ds.day;


-- ════════════════════════════════════════════════════════════
-- 6.2  RECURSIVE CTE — Org hierarchy traversal
--      Find all reports under a given manager (any depth)
-- ════════════════════════════════════════════════════════════

-- (Illustrative: add employees table in schema if needed)
-- CREATE TABLE employees (
--     emp_id INT PRIMARY KEY, name TEXT,
--     manager_id INT REFERENCES employees(emp_id), level INT
-- );

WITH RECURSIVE org_tree AS (
    -- Base: start from a given manager (e.g., CEO = manager_id IS NULL)
    SELECT emp_id, name, manager_id, 1 AS depth,
           ARRAY[emp_id] AS path,        -- Track path to detect cycles
           name::TEXT    AS full_path
    FROM employees
    WHERE manager_id IS NULL  -- Root node(s)

    UNION ALL

    -- Recursive: find all direct reports
    SELECT
        e.emp_id, e.name, e.manager_id,
        ot.depth + 1,
        ot.path || e.emp_id,
        ot.full_path || ' > ' || e.name
    FROM employees e
    JOIN org_tree ot ON e.manager_id = ot.emp_id
    WHERE NOT e.emp_id = ANY(ot.path)   -- Cycle guard
      AND ot.depth < 10                 -- Max depth safety
)
SELECT
    emp_id,
    LPAD('', (depth - 1) * 4, ' ') || name AS indented_name,
    depth,
    full_path
FROM org_tree
ORDER BY path;


-- ════════════════════════════════════════════════════════════
-- 6.3  LATERAL JOIN — Row-by-row subquery execution
--      More powerful than correlated subquery, cleaner than
--      window functions for "top N per group with full row"
-- ════════════════════════════════════════════════════════════

-- For each user, get their top 2 most expensive orders with full details
SELECT
    u.user_id,
    u.email,
    u.plan,
    top_orders.order_id,
    top_orders.order_date::DATE,
    top_orders.net_revenue,
    top_orders.revenue_rank
FROM users u
CROSS JOIN LATERAL (
    SELECT
        r.order_id,
        r.order_date,
        r.net_revenue,
        ROW_NUMBER() OVER (ORDER BY r.net_revenue DESC) AS revenue_rank
    FROM order_revenue r
    WHERE r.user_id = u.user_id
    ORDER BY r.net_revenue DESC
    LIMIT 2
) AS top_orders
ORDER BY u.user_id, top_orders.revenue_rank;


-- ════════════════════════════════════════════════════════════
-- 6.4  DEDUPLICATION PATTERNS
--      The right way to handle duplicates in production data
-- ════════════════════════════════════════════════════════════

-- Pattern 1: Keep most recent record per business key
-- Use case: raw events table with duplicate clicks/page views

WITH deduped_events AS (
    SELECT *,
           ROW_NUMBER() OVER (
               PARTITION BY user_id, session_id, event_type
               ORDER BY event_at DESC      -- Keep latest
           ) AS rn
    FROM events
)
SELECT * EXCLUDE (rn)
FROM deduped_events
WHERE rn = 1;


-- Pattern 2: Find duplicates before removing them (audit first!)
SELECT
    user_id,
    session_id,
    event_type,
    COUNT(*)          AS duplicate_count,
    MIN(event_at)     AS first_seen,
    MAX(event_at)     AS last_seen,
    MAX(event_at) - MIN(event_at) AS time_span
FROM events
GROUP BY 1, 2, 3
HAVING COUNT(*) > 1
ORDER BY duplicate_count DESC;


-- Pattern 3: Fuzzy dedup — same email, different format variations
-- (e.g., "user+tag@email.com" vs "user@email.com")
SELECT
    user_id,
    email,
    -- Normalise email: lowercase, strip tags (gmail +tag trick)
    LOWER(
        REGEXP_REPLACE(
            SPLIT_PART(email, '@', 1),
            '\+.*$', ''    -- Remove everything after +
        ) || '@' || SPLIT_PART(LOWER(email), '@', 2)
    ) AS normalised_email,
    COUNT(*) OVER (
        PARTITION BY LOWER(
            REGEXP_REPLACE(SPLIT_PART(email, '@', 1), '\+.*$', '')
            || '@' || SPLIT_PART(LOWER(email), '@', 2)
        )
    ) AS variants_count
FROM users
ORDER BY normalised_email;
