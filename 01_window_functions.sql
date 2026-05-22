-- ============================================================
-- MODULE 01: Window Functions
-- The most powerful and underused feature in SQL analytics
-- ============================================================

-- ── Setup: use the e-commerce schema (schema/create_tables.sql) ──────────────

-- ════════════════════════════════════════════════════════════
-- 1.1  RANKING FUNCTIONS
--      ROW_NUMBER vs RANK vs DENSE_RANK — when each matters
-- ════════════════════════════════════════════════════════════

-- ROW_NUMBER: unique sequential rank. Best for "top N per group" with no ties.
-- RANK:       ties get same rank, next rank skips (1,2,2,4)
-- DENSE_RANK: ties get same rank, no gaps       (1,2,2,3)

SELECT
    user_id,
    order_date::DATE,
    net_revenue,

    -- Overall ranking by revenue descending
    ROW_NUMBER() OVER (ORDER BY net_revenue DESC)               AS rn_overall,
    RANK()       OVER (ORDER BY net_revenue DESC)               AS rank_overall,
    DENSE_RANK() OVER (ORDER BY net_revenue DESC)               AS dense_rank_overall,

    -- Ranking WITHIN each calendar month (partition resets per month)
    ROW_NUMBER() OVER (
        PARTITION BY DATE_TRUNC('month', order_date)
        ORDER BY net_revenue DESC
    )                                                           AS rn_within_month,

    -- Percentile bucket (0–100) within the full dataset
    NTILE(100) OVER (ORDER BY net_revenue DESC)                 AS percentile_bucket

FROM order_revenue
ORDER BY order_date DESC, net_revenue DESC;


-- ── Top 3 orders per user (classic "top N per group" pattern) ─────────────────
-- Without window functions, this requires a messy self-join.
-- With ROW_NUMBER + CTE it's clean and fast.

WITH ranked_orders AS (
    SELECT
        user_id,
        order_id,
        order_date::DATE,
        net_revenue,
        ROW_NUMBER() OVER (
            PARTITION BY user_id
            ORDER BY net_revenue DESC
        ) AS revenue_rank
    FROM order_revenue
)
SELECT *
FROM ranked_orders
WHERE revenue_rank <= 3
ORDER BY user_id, revenue_rank;


-- ════════════════════════════════════════════════════════════
-- 1.2  LAG / LEAD — Access adjacent rows without self-join
-- ════════════════════════════════════════════════════════════

-- MoM revenue growth per user — how much did each user's spend change?
WITH monthly_user_revenue AS (
    SELECT
        user_id,
        DATE_TRUNC('month', order_date)::DATE AS month,
        SUM(net_revenue)                       AS monthly_revenue
    FROM order_revenue
    GROUP BY 1, 2
),
with_lag AS (
    SELECT
        user_id,
        month,
        monthly_revenue,
        -- Previous month's revenue for this user (NULL for first month)
        LAG(monthly_revenue, 1) OVER (
            PARTITION BY user_id
            ORDER BY month
        )                                                   AS prev_month_revenue,

        -- Next month's revenue (useful for forecasting comparisons)
        LEAD(monthly_revenue, 1) OVER (
            PARTITION BY user_id
            ORDER BY month
        )                                                   AS next_month_revenue,

        -- How many months since this user's first order?
        ROW_NUMBER() OVER (
            PARTITION BY user_id
            ORDER BY month
        ) - 1                                               AS months_since_first_order
    FROM monthly_user_revenue
)
SELECT
    user_id,
    month,
    monthly_revenue,
    prev_month_revenue,
    ROUND(
        100.0 * (monthly_revenue - prev_month_revenue) / NULLIF(prev_month_revenue, 0),
        1
    )                                                       AS mom_growth_pct,
    months_since_first_order,
    -- Classify growth trajectory
    CASE
        WHEN prev_month_revenue IS NULL                     THEN 'first_order'
        WHEN monthly_revenue > prev_month_revenue * 1.20   THEN 'strong_growth'
        WHEN monthly_revenue > prev_month_revenue * 1.05   THEN 'moderate_growth'
        WHEN monthly_revenue >= prev_month_revenue * 0.95  THEN 'stable'
        WHEN monthly_revenue >= prev_month_revenue * 0.80  THEN 'declining'
        ELSE                                                     'significant_decline'
    END                                                     AS growth_category
FROM with_lag
ORDER BY user_id, month;


-- ════════════════════════════════════════════════════════════
-- 1.3  RUNNING TOTALS & MOVING AVERAGES
--      ROWS vs RANGE frame specifications — a subtle but
--      critical difference
-- ════════════════════════════════════════════════════════════

WITH daily_revenue AS (
    SELECT
        order_date::DATE         AS day,
        SUM(net_revenue)         AS daily_rev
    FROM order_revenue
    GROUP BY 1
)
SELECT
    day,
    daily_rev,

    -- Cumulative sum (running total from day 1 to current row)
    SUM(daily_rev) OVER (
        ORDER BY day
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    )                                               AS cumulative_revenue,

    -- 7-day simple moving average (last 6 days + today)
    ROUND(AVG(daily_rev) OVER (
        ORDER BY day
        ROWS BETWEEN 6 PRECEDING AND CURRENT ROW
    ), 2)                                           AS ma_7d,

    -- 30-day moving average
    ROUND(AVG(daily_rev) OVER (
        ORDER BY day
        ROWS BETWEEN 29 PRECEDING AND CURRENT ROW
    ), 2)                                           AS ma_30d,

    -- 7-day moving max (useful for spotting record days)
    MAX(daily_rev) OVER (
        ORDER BY day
        ROWS BETWEEN 6 PRECEDING AND CURRENT ROW
    )                                               AS max_7d,

    -- Cumulative average (expanding window)
    ROUND(AVG(daily_rev) OVER (
        ORDER BY day
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ), 2)                                           AS expanding_avg,

    -- % of cumulative total (for revenue concentration analysis)
    ROUND(
        100.0 * daily_rev /
        SUM(daily_rev) OVER (),  -- Grand total (no ORDER BY = whole partition)
        2
    )                                               AS pct_of_total_revenue

FROM daily_revenue
ORDER BY day;


-- ════════════════════════════════════════════════════════════
-- 1.4  FIRST_VALUE / LAST_VALUE / NTH_VALUE
-- ════════════════════════════════════════════════════════════

-- For each user: compare every order against their first and most recent purchase
SELECT
    user_id,
    order_id,
    order_date::DATE,
    net_revenue,

    -- First order details
    FIRST_VALUE(net_revenue) OVER w     AS first_order_revenue,
    FIRST_VALUE(order_date::DATE) OVER w AS first_order_date,

    -- Most recent order (LAST_VALUE needs explicit frame — gotcha!)
    LAST_VALUE(net_revenue) OVER (
        PARTITION BY user_id
        ORDER BY order_date
        ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
    )                                   AS latest_order_revenue,

    -- Revenue vs first order (growth indicator)
    ROUND(
        100.0 * (net_revenue - FIRST_VALUE(net_revenue) OVER w)
               / NULLIF(FIRST_VALUE(net_revenue) OVER w, 0),
        1
    )                                   AS pct_change_vs_first_order,

    -- Order number for this user
    ROW_NUMBER() OVER w                 AS order_number

FROM order_revenue
WINDOW w AS (PARTITION BY user_id ORDER BY order_date
             ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
ORDER BY user_id, order_date;
