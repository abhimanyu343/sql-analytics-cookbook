-- ============================================================
-- MODULE 04: SaaS Revenue Metrics
-- MRR, ARR, Churn, Expansion, LTV — the metrics that matter
-- ============================================================

-- ════════════════════════════════════════════════════════════
-- 4.1  MONTHLY RECURRING REVENUE (MRR) BREAKDOWN
--      MRR = New + Expansion + Reactivation - Contraction - Churn
-- ════════════════════════════════════════════════════════════

WITH
-- All subscription state changes, month by month
monthly_mrr AS (
    SELECT
        user_id,
        DATE_TRUNC('month', started_at)::DATE      AS month,
        mrr                                         AS current_mrr,
        LAG(mrr) OVER (PARTITION BY user_id ORDER BY started_at) AS prev_mrr
    FROM subscriptions
),

-- Classify each MRR change
mrr_movements AS (
    SELECT
        month,
        user_id,
        current_mrr,
        prev_mrr,
        CASE
            WHEN prev_mrr IS NULL AND current_mrr > 0     THEN 'new'
            WHEN prev_mrr IS NOT NULL
                 AND current_mrr > prev_mrr               THEN 'expansion'
            WHEN prev_mrr IS NOT NULL
                 AND current_mrr < prev_mrr
                 AND current_mrr > 0                      THEN 'contraction'
            WHEN prev_mrr > 0 AND current_mrr = 0         THEN 'churn'
            WHEN prev_mrr = 0 AND current_mrr > 0         THEN 'reactivation'
            ELSE                                               'unchanged'
        END AS movement_type,
        current_mrr - COALESCE(prev_mrr, 0)           AS mrr_delta
    FROM monthly_mrr
    WHERE current_mrr != COALESCE(prev_mrr, 0)  -- Only record actual changes
)

SELECT
    month,

    -- MRR by component
    ROUND(SUM(mrr_delta) FILTER (WHERE movement_type = 'new'),          2) AS new_mrr,
    ROUND(SUM(mrr_delta) FILTER (WHERE movement_type = 'expansion'),    2) AS expansion_mrr,
    ROUND(SUM(mrr_delta) FILTER (WHERE movement_type = 'reactivation'), 2) AS reactivation_mrr,
    ROUND(SUM(mrr_delta) FILTER (WHERE movement_type = 'contraction'),  2) AS contraction_mrr,
    ROUND(SUM(mrr_delta) FILTER (WHERE movement_type = 'churn'),        2) AS churn_mrr,

    -- Net new MRR
    ROUND(SUM(mrr_delta), 2) AS net_new_mrr,

    -- Ending MRR (running total)
    ROUND(SUM(SUM(mrr_delta)) OVER (ORDER BY month
          ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW), 2) AS ending_mrr,

    -- Count of each movement type
    COUNT(*) FILTER (WHERE movement_type = 'new')      AS new_customers,
    COUNT(*) FILTER (WHERE movement_type = 'churn')    AS churned_customers,
    COUNT(*) FILTER (WHERE movement_type = 'expansion') AS expanded_customers

FROM mrr_movements
GROUP BY month
ORDER BY month;


-- ════════════════════════════════════════════════════════════
-- 4.2  CHURN RATE & NET REVENUE RETENTION (NRR)
--      NRR > 100% = revenue grows from existing customers alone
-- ════════════════════════════════════════════════════════════

WITH
monthly_cohort_mrr AS (
    SELECT
        user_id,
        DATE_TRUNC('month', started_at)::DATE AS month,
        mrr
    FROM subscriptions
    WHERE ended_at IS NULL OR ended_at > started_at
),
with_lag AS (
    SELECT
        month,
        user_id,
        mrr,
        LAG(mrr) OVER (PARTITION BY user_id ORDER BY month) AS prev_mrr
    FROM monthly_cohort_mrr
),
monthly_totals AS (
    SELECT
        month,
        SUM(mrr)                                     AS ending_mrr,
        SUM(COALESCE(prev_mrr, 0))                   AS beginning_mrr,
        -- Churned revenue = MRR that existed last month but is now 0
        SUM(CASE WHEN mrr = 0 AND prev_mrr > 0
                 THEN prev_mrr ELSE 0 END)           AS churned_mrr,
        -- Expanded revenue = additional MRR from existing customers
        SUM(CASE WHEN mrr > COALESCE(prev_mrr, 0) AND prev_mrr > 0
                 THEN mrr - prev_mrr ELSE 0 END)     AS expansion_mrr
    FROM with_lag
    GROUP BY month
)
SELECT
    month,
    ROUND(beginning_mrr, 2)                                              AS beginning_mrr,
    ROUND(ending_mrr, 2)                                                 AS ending_mrr,
    ROUND(churned_mrr, 2)                                                AS churned_mrr,
    ROUND(expansion_mrr, 2)                                              AS expansion_mrr,

    -- Gross MRR Churn Rate = Churned MRR / Beginning MRR
    ROUND(100.0 * churned_mrr / NULLIF(beginning_mrr, 0), 2)            AS gross_churn_rate_pct,

    -- Net Revenue Retention = (Beginning + Expansion - Churn) / Beginning × 100
    -- NRR > 100% means revenue grows without any new customers
    ROUND(100.0 * (beginning_mrr + expansion_mrr - churned_mrr)
          / NULLIF(beginning_mrr, 0), 1)                                 AS nrr_pct,

    -- Quick Ratio = (New + Expansion) / (Churn + Contraction)
    -- QR > 4 = hypergrowth, QR < 1 = declining
    ROUND((ending_mrr - beginning_mrr + churned_mrr)
          / NULLIF(churned_mrr, 0), 2)                                   AS quick_ratio

FROM monthly_totals
ORDER BY month;


-- ════════════════════════════════════════════════════════════
-- 4.3  CUSTOMER LIFETIME VALUE (LTV) BY SEGMENT
--      LTV = ARPU / Churn Rate
--      Also compute payback period (LTV / CAC proxy)
-- ════════════════════════════════════════════════════════════

WITH
customer_metrics AS (
    SELECT
        u.user_id,
        u.plan,
        u.acquired_channel,
        -- Total revenue from this customer
        SUM(r.net_revenue)                            AS total_revenue,
        -- Active months (tenure)
        COUNT(DISTINCT DATE_TRUNC('month', r.order_date)) AS active_months,
        -- Average monthly revenue
        AVG(r.net_revenue)                            AS avg_order_value,
        MIN(r.order_date)                             AS first_order,
        MAX(r.order_date)                             AS last_order,
        -- Still active? (ordered in last 90 days)
        CASE WHEN MAX(r.order_date) > NOW() - INTERVAL '90 days'
             THEN TRUE ELSE FALSE END                 AS is_active
    FROM users u
    JOIN order_revenue r USING (user_id)
    GROUP BY 1, 2, 3
)
SELECT
    plan,
    acquired_channel,
    COUNT(*)                                          AS customer_count,
    ROUND(AVG(total_revenue), 2)                      AS avg_total_revenue,
    ROUND(AVG(avg_order_value), 2)                    AS avg_order_value,
    ROUND(AVG(active_months), 1)                      AS avg_active_months,
    ROUND(AVG(total_revenue / NULLIF(active_months, 0)), 2) AS avg_monthly_revenue,

    -- Simple LTV estimate: avg monthly revenue × expected lifetime months
    -- Churn rate estimated from is_active flag
    ROUND(
        AVG(total_revenue / NULLIF(active_months, 0))
        * (1.0 / NULLIF(AVG(CASE WHEN NOT is_active THEN 1.0 ELSE 0 END), 0)),
        2
    )                                                 AS estimated_ltv,

    -- Revenue concentration: top 10% of customers' share of total revenue
    ROUND(100.0 * PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY total_revenue)
          / SUM(total_revenue) * COUNT(*) * 0.1, 1)   AS top10pct_revenue_share_pct

FROM customer_metrics
GROUP BY plan, acquired_channel
ORDER BY estimated_ltv DESC NULLS LAST;
