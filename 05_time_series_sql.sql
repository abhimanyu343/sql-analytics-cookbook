-- ============================================================
-- MODULE 05: Time-Series Analysis in SQL
-- Gap filling, YoY/MoM, rolling windows, period comparisons
-- ============================================================

-- ════════════════════════════════════════════════════════════
-- 5.1  GAP FILLING with GENERATE_SERIES
--      Ensure every date appears even with zero activity
-- ════════════════════════════════════════════════════════════

WITH date_spine AS (
    SELECT generate_series(
        DATE_TRUNC('day', (SELECT MIN(order_date) FROM orders)),
        DATE_TRUNC('day', (SELECT MAX(order_date) FROM orders)),
        '1 day'::INTERVAL
    )::DATE AS day
),
daily AS (
    SELECT order_date::DATE AS day, SUM(net_revenue) AS revenue, COUNT(*) AS orders
    FROM order_revenue GROUP BY 1
)
SELECT
    ds.day,
    COALESCE(d.revenue, 0)  AS revenue,
    COALESCE(d.orders, 0)   AS orders,
    -- Forward-fill last known revenue (carries value over gaps)
    COALESCE(d.revenue,
        LAST_VALUE(d.revenue) OVER (
            ORDER BY ds.day
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        )
    ) AS revenue_ffill
FROM date_spine ds
LEFT JOIN daily d ON d.day = ds.day
ORDER BY ds.day;


-- ════════════════════════════════════════════════════════════
-- 5.2  YEAR-OVER-YEAR & MONTH-OVER-MONTH COMPARISON
-- ════════════════════════════════════════════════════════════

WITH monthly AS (
    SELECT DATE_TRUNC('month', order_date)::DATE AS month,
           SUM(net_revenue) AS revenue
    FROM order_revenue GROUP BY 1
)
SELECT
    month,
    revenue,
    -- Month over month
    LAG(revenue, 1) OVER (ORDER BY month)                  AS prev_month,
    ROUND(100.0 * (revenue - LAG(revenue, 1) OVER (ORDER BY month))
          / NULLIF(LAG(revenue, 1) OVER (ORDER BY month), 0), 1) AS mom_pct,
    -- Year over year (12 months back)
    LAG(revenue, 12) OVER (ORDER BY month)                 AS same_month_last_year,
    ROUND(100.0 * (revenue - LAG(revenue, 12) OVER (ORDER BY month))
          / NULLIF(LAG(revenue, 12) OVER (ORDER BY month), 0), 1) AS yoy_pct,
    -- 3-month moving average
    ROUND(AVG(revenue) OVER (ORDER BY month ROWS BETWEEN 2 PRECEDING AND CURRENT ROW), 0) AS ma_3mo
FROM monthly
ORDER BY month;


-- ════════════════════════════════════════════════════════════
-- 5.3  ROLLING RETENTION WINDOW (active in last N days)
-- ════════════════════════════════════════════════════════════

WITH daily_active AS (
    SELECT order_date::DATE AS day, COUNT(DISTINCT user_id) AS dau
    FROM order_revenue GROUP BY 1
)
SELECT
    day,
    dau,
    -- 7-day and 30-day rolling unique-active proxy (sum of daily actives)
    SUM(dau) OVER (ORDER BY day ROWS BETWEEN 6 PRECEDING AND CURRENT ROW)  AS rolling_7d_activity,
    SUM(dau) OVER (ORDER BY day ROWS BETWEEN 29 PRECEDING AND CURRENT ROW) AS rolling_30d_activity,
    -- Stickiness ratio: DAU / 30d activity
    ROUND(100.0 * dau / NULLIF(
        AVG(dau) OVER (ORDER BY day ROWS BETWEEN 29 PRECEDING AND CURRENT ROW), 0), 1)
        AS dau_to_avg_ratio_pct
FROM daily_active
ORDER BY day;


-- ════════════════════════════════════════════════════════════
-- 5.4  SESSIONIZATION — group events into sessions by time gap
--      New session if gap > 30 minutes (industry standard)
-- ════════════════════════════════════════════════════════════

WITH event_gaps AS (
    SELECT
        user_id,
        event_at,
        event_type,
        -- Time since previous event for this user
        EXTRACT(EPOCH FROM (event_at - LAG(event_at) OVER (
            PARTITION BY user_id ORDER BY event_at))) / 60 AS minutes_since_prev
    FROM events
    WHERE user_id IS NOT NULL
),
session_flags AS (
    SELECT *,
        -- New session starts when gap > 30 min OR it's the first event
        CASE WHEN minutes_since_prev IS NULL OR minutes_since_prev > 30
             THEN 1 ELSE 0 END AS is_new_session
    FROM event_gaps
),
sessionized AS (
    SELECT *,
        -- Cumulative sum of new-session flags = session number per user
        SUM(is_new_session) OVER (
            PARTITION BY user_id ORDER BY event_at
        ) AS session_num
    FROM session_flags
)
SELECT
    user_id,
    session_num,
    COUNT(*)                                                       AS events_in_session,
    MIN(event_at)                                                  AS session_start,
    MAX(event_at)                                                  AS session_end,
    ROUND(EXTRACT(EPOCH FROM (MAX(event_at) - MIN(event_at)))/60, 1) AS duration_min,
    BOOL_OR(event_type = 'purchase')                              AS converted
FROM sessionized
GROUP BY user_id, session_num
ORDER BY user_id, session_num
LIMIT 100;
