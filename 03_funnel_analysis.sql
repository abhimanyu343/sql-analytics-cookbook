-- ============================================================
-- MODULE 03: Funnel & Conversion Analysis
-- Track users through a multi-step journey, find the leaks
-- ============================================================

-- ════════════════════════════════════════════════════════════
-- 3.1  BASIC CONVERSION FUNNEL
--      page_view → add_to_cart → checkout_start → purchase
-- ════════════════════════════════════════════════════════════

WITH funnel_steps AS (
    SELECT
        session_id,
        MAX((event_type = 'page_view')::INT)      AS reached_view,
        MAX((event_type = 'add_to_cart')::INT)    AS reached_cart,
        MAX((event_type = 'checkout_start')::INT) AS reached_checkout,
        MAX((event_type = 'purchase')::INT)       AS reached_purchase
    FROM events
    GROUP BY session_id
)
SELECT
    SUM(reached_view)        AS step1_page_views,
    SUM(reached_cart)        AS step2_add_to_cart,
    SUM(reached_checkout)    AS step3_checkout,
    SUM(reached_purchase)    AS step4_purchase,

    -- Step-to-step conversion rates
    ROUND(100.0 * SUM(reached_cart) / NULLIF(SUM(reached_view), 0), 1)        AS view_to_cart_pct,
    ROUND(100.0 * SUM(reached_checkout) / NULLIF(SUM(reached_cart), 0), 1)    AS cart_to_checkout_pct,
    ROUND(100.0 * SUM(reached_purchase) / NULLIF(SUM(reached_checkout), 0), 1) AS checkout_to_purchase_pct,

    -- Overall conversion (view → purchase)
    ROUND(100.0 * SUM(reached_purchase) / NULLIF(SUM(reached_view), 0), 2)    AS overall_conversion_pct
FROM funnel_steps;


-- ════════════════════════════════════════════════════════════
-- 3.2  FUNNEL SEGMENTED BY DEVICE — where do we lose mobile users?
-- ════════════════════════════════════════════════════════════

WITH session_device AS (
    -- Each session's primary device (mode)
    SELECT session_id, MODE() WITHIN GROUP (ORDER BY device_type) AS device
    FROM events GROUP BY session_id
),
funnel_steps AS (
    SELECT
        e.session_id,
        sd.device,
        MAX((event_type = 'page_view')::INT)      AS v,
        MAX((event_type = 'add_to_cart')::INT)    AS c,
        MAX((event_type = 'checkout_start')::INT) AS ck,
        MAX((event_type = 'purchase')::INT)       AS p
    FROM events e
    JOIN session_device sd USING (session_id)
    GROUP BY e.session_id, sd.device
)
SELECT
    device,
    COUNT(*)                                              AS sessions,
    SUM(v)                                                AS views,
    SUM(p)                                                AS purchases,
    ROUND(100.0 * SUM(c)  / NULLIF(SUM(v), 0), 1)        AS view_to_cart_pct,
    ROUND(100.0 * SUM(ck) / NULLIF(SUM(c), 0), 1)        AS cart_to_checkout_pct,
    ROUND(100.0 * SUM(p)  / NULLIF(SUM(ck), 0), 1)       AS checkout_to_purchase_pct,
    ROUND(100.0 * SUM(p)  / NULLIF(SUM(v), 0), 2)        AS overall_conversion_pct
FROM funnel_steps
GROUP BY device
ORDER BY overall_conversion_pct DESC;


-- ════════════════════════════════════════════════════════════
-- 3.3  TIME-TO-CONVERT — how long from first view to purchase?
-- ════════════════════════════════════════════════════════════

WITH session_journey AS (
    SELECT
        session_id,
        MIN(event_at) FILTER (WHERE event_type = 'page_view') AS first_view,
        MIN(event_at) FILTER (WHERE event_type = 'purchase')  AS purchase_time
    FROM events
    GROUP BY session_id
    HAVING MIN(event_at) FILTER (WHERE event_type = 'purchase') IS NOT NULL
)
SELECT
    COUNT(*)                                                          AS converting_sessions,
    ROUND(AVG(EXTRACT(EPOCH FROM (purchase_time - first_view))/60), 1) AS avg_minutes_to_convert,
    ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (
        ORDER BY EXTRACT(EPOCH FROM (purchase_time - first_view))/60), 1) AS median_minutes,
    ROUND(PERCENTILE_CONT(0.9) WITHIN GROUP (
        ORDER BY EXTRACT(EPOCH FROM (purchase_time - first_view))/60), 1) AS p90_minutes
FROM session_journey
WHERE purchase_time >= first_view;


-- ════════════════════════════════════════════════════════════
-- 3.4  DROP-OFF ANALYSIS — exactly where users abandon
-- ════════════════════════════════════════════════════════════

WITH funnel_steps AS (
    SELECT session_id,
        MAX((event_type = 'page_view')::INT)      AS s1,
        MAX((event_type = 'add_to_cart')::INT)    AS s2,
        MAX((event_type = 'checkout_start')::INT) AS s3,
        MAX((event_type = 'purchase')::INT)       AS s4
    FROM events GROUP BY session_id
),
stage_counts AS (
    SELECT
        SUM(s1) AS viewed, SUM(s2) AS carted,
        SUM(s3) AS checkout, SUM(s4) AS purchased
    FROM funnel_steps
)
SELECT step, users_reached, dropped_off, drop_off_pct FROM (
    SELECT 1 AS ord, '1. Viewed' AS step, viewed AS users_reached,
           viewed - carted AS dropped_off,
           ROUND(100.0 * (viewed - carted) / NULLIF(viewed, 0), 1) AS drop_off_pct
    FROM stage_counts
    UNION ALL
    SELECT 2, '2. Added to cart', carted, carted - checkout,
           ROUND(100.0 * (carted - checkout) / NULLIF(carted, 0), 1) FROM stage_counts
    UNION ALL
    SELECT 3, '3. Started checkout', checkout, checkout - purchased,
           ROUND(100.0 * (checkout - purchased) / NULLIF(checkout, 0), 1) FROM stage_counts
    UNION ALL
    SELECT 4, '4. Purchased', purchased, 0, 0.0 FROM stage_counts
) t ORDER BY ord;
