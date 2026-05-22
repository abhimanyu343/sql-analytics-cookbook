-- ============================================================
-- MODULE 02: Cohort Retention Analysis
-- The most important metric for subscription & repeat-purchase businesses
-- ============================================================

-- ════════════════════════════════════════════════════════════
-- 2.1  MONTHLY COHORT RETENTION TABLE
--      Classic cohort analysis: group users by acquisition month,
--      track what % return in months 1, 2, 3...
-- ════════════════════════════════════════════════════════════

WITH
-- Step 1: Tag each user with their acquisition cohort month
user_cohorts AS (
    SELECT
        user_id,
        DATE_TRUNC('month', MIN(order_date))::DATE AS cohort_month
    FROM order_revenue
    GROUP BY user_id
),

-- Step 2: For each user-month pair, record activity
user_monthly_activity AS (
    SELECT DISTINCT
        r.user_id,
        DATE_TRUNC('month', r.order_date)::DATE AS activity_month
    FROM order_revenue r
),

-- Step 3: Join to get cohort + activity month, compute period offset
cohort_data AS (
    SELECT
        uc.cohort_month,
        uma.activity_month,
        -- Period index: 0 = acquisition month, 1 = month after, etc.
        (DATE_PART('year', age(uma.activity_month, uc.cohort_month)) * 12 +
         DATE_PART('month', age(uma.activity_month, uc.cohort_month)))::INT AS period,
        COUNT(DISTINCT uc.user_id)                                           AS active_users
    FROM user_cohorts uc
    JOIN user_monthly_activity uma USING (user_id)
    WHERE uma.activity_month >= uc.cohort_month
    GROUP BY 1, 2, 3
),

-- Step 4: Get cohort sizes (period 0 = acquisition count)
cohort_sizes AS (
    SELECT cohort_month, active_users AS cohort_size
    FROM cohort_data
    WHERE period = 0
)

-- Step 5: Final retention table with absolute users + retention %
SELECT
    cd.cohort_month,
    cs.cohort_size,
    cd.period,
    cd.active_users,
    ROUND(100.0 * cd.active_users / cs.cohort_size, 1) AS retention_pct
FROM cohort_data cd
JOIN cohort_sizes cs USING (cohort_month)
ORDER BY cd.cohort_month, cd.period;


-- ════════════════════════════════════════════════════════════
-- 2.2  PIVOT THE COHORT TABLE (for heatmap display)
--      Periods as columns — ready for Excel/BI tool heatmap
-- ════════════════════════════════════════════════════════════

-- PostgreSQL pivot using FILTER (ANSI SQL compatible)
WITH
user_cohorts AS (
    SELECT user_id, DATE_TRUNC('month', MIN(order_date))::DATE AS cohort_month
    FROM order_revenue GROUP BY 1
),
user_monthly_activity AS (
    SELECT DISTINCT user_id, DATE_TRUNC('month', order_date)::DATE AS activity_month
    FROM order_revenue
),
cohort_retention AS (
    SELECT
        uc.cohort_month,
        (DATE_PART('year', age(uma.activity_month, uc.cohort_month)) * 12 +
         DATE_PART('month', age(uma.activity_month, uc.cohort_month)))::INT AS period,
        COUNT(DISTINCT uc.user_id)                                           AS active_users,
        COUNT(DISTINCT uc.user_id) FILTER (WHERE period = 0)
            OVER (PARTITION BY uc.cohort_month)                              AS cohort_size
    FROM user_cohorts uc
    JOIN user_monthly_activity uma USING (user_id)
    WHERE uma.activity_month >= uc.cohort_month
    GROUP BY 1, 2
)
SELECT
    cohort_month,
    MAX(cohort_size)                                                 AS cohort_size,
    -- Retention % for periods 0–6 (extend as needed)
    ROUND(100.0 * SUM(active_users) FILTER (WHERE period = 0) / MAX(cohort_size), 1) AS "M0_%",
    ROUND(100.0 * SUM(active_users) FILTER (WHERE period = 1) / MAX(cohort_size), 1) AS "M1_%",
    ROUND(100.0 * SUM(active_users) FILTER (WHERE period = 2) / MAX(cohort_size), 1) AS "M2_%",
    ROUND(100.0 * SUM(active_users) FILTER (WHERE period = 3) / MAX(cohort_size), 1) AS "M3_%",
    ROUND(100.0 * SUM(active_users) FILTER (WHERE period = 6) / MAX(cohort_size), 1) AS "M6_%",
    ROUND(100.0 * SUM(active_users) FILTER (WHERE period = 12) / MAX(cohort_size), 1) AS "M12_%"
FROM cohort_retention
GROUP BY cohort_month
ORDER BY cohort_month;


-- ════════════════════════════════════════════════════════════
-- 2.3  REVENUE COHORT ANALYSIS
--      Track revenue per cohort over time (not just user counts)
--      Reveals if retained users spend more or less over time
-- ════════════════════════════════════════════════════════════

WITH
user_cohorts AS (
    SELECT user_id, DATE_TRUNC('month', MIN(order_date))::DATE AS cohort_month
    FROM order_revenue GROUP BY 1
),
cohort_revenue AS (
    SELECT
        uc.cohort_month,
        (DATE_PART('year', age(DATE_TRUNC('month', r.order_date)::DATE, uc.cohort_month)) * 12 +
         DATE_PART('month', age(DATE_TRUNC('month', r.order_date)::DATE, uc.cohort_month)))::INT AS period,
        COUNT(DISTINCT uc.user_id)  AS active_users,
        SUM(r.net_revenue)          AS total_revenue,
        AVG(r.net_revenue)          AS avg_order_revenue
    FROM user_cohorts uc
    JOIN order_revenue r USING (user_id)
    WHERE r.order_date >= uc.cohort_month::TIMESTAMPTZ
    GROUP BY 1, 2
),
cohort_baselines AS (
    SELECT cohort_month,
           active_users  AS cohort_size,
           total_revenue AS period0_revenue
    FROM cohort_revenue WHERE period = 0
)
SELECT
    cr.cohort_month,
    cb.cohort_size,
    cr.period,
    cr.active_users,
    ROUND(cr.total_revenue, 2)                                     AS cohort_revenue,
    ROUND(cr.avg_order_revenue, 2)                                 AS avg_order_value,
    -- Revenue per user in this cohort at this period
    ROUND(cr.total_revenue / NULLIF(cr.active_users, 0), 2)       AS revenue_per_active_user,
    -- Cumulative revenue per original cohort member (LTV proxy)
    ROUND(SUM(cr.total_revenue) OVER (
        PARTITION BY cr.cohort_month
        ORDER BY cr.period
    ) / cb.cohort_size, 2)                                         AS cumulative_ltv_per_user,
    -- Revenue retention % vs period 0
    ROUND(100.0 * cr.total_revenue / NULLIF(cb.period0_revenue, 0), 1) AS revenue_retention_pct
FROM cohort_revenue cr
JOIN cohort_baselines cb USING (cohort_month)
ORDER BY cr.cohort_month, cr.period;
