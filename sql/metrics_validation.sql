WITH monthly_revenue AS ( 
SELECT	
	user_id,
	date_trunc('month', payment_date)::date AS payment_month,
	sum(revenue_amount_usd) AS total_revenue
FROM project.games_payments
GROUP BY 1,2
),
payment_calendar AS (
SELECT 
	user_id ,
	payment_month,
	total_revenue,
	(payment_month - INTERVAL '1 month')::date as previous_calendar_month,
    (payment_month + INTERVAL '1 month')::date as next_calendar_month,
	MIN(payment_month ) OVER (PARTITION BY user_id ORDER BY payment_month ) AS first_payment_month,
	LAG (payment_month) OVER (PARTITION BY user_id ORDER BY payment_month ) AS previous_paid_month,
	LAG	(total_revenue) OVER (PARTITION BY user_id ORDER BY payment_month ) AS previous_paid_month_revenue,
	LEAD(payment_month) OVER (PARTITION BY user_id ORDER BY payment_month) AS next_paid_month,
	LEAD(total_revenue) OVER (PARTITION BY user_id ORDER BY payment_month) AS next_paid_month_revenue
FROM monthly_revenue),
metrics AS (
SELECT *,
	CASE WHEN payment_month=first_payment_month
	THEN total_revenue
	ELSE 0  END AS new_mrr,
	CASE WHEN previous_calendar_month=previous_paid_month AND total_revenue > previous_paid_month_revenue
	THEN total_revenue - previous_paid_month_revenue
	ELSE 0 END AS expansion_revenue,
	CASE WHEN previous_calendar_month=previous_paid_month AND total_revenue < previous_paid_month_revenue
	THEN total_revenue - previous_paid_month_revenue
	ELSE 0 END AS contraction_revenue,
	CASE WHEN previous_paid_month IS NOT NULL AND previous_paid_month<previous_calendar_month
	THEN total_revenue
	ELSE 0 END AS back_from_churn_revenue
FROM payment_calendar),
final_table AS(
SELECT 
	m.user_id,
	payment_month AS report_month,
	total_revenue,
	previous_calendar_month,
	next_calendar_month,
	first_payment_month,
	previous_paid_month,
	previous_paid_month_revenue,
	next_paid_month,
	next_paid_month_revenue,
	new_mrr,
	expansion_revenue,
	contraction_revenue,
	back_from_churn_revenue,
	0 AS churned_revenue,
	gpu.game_name, 
	gpu.language, 
	gpu.has_older_device_model,
	gpu.age
FROM metrics m
LEFT JOIN games_paid_users gpu ON m.user_id=gpu.user_id

UNION ALL 

SELECT 
	m.user_id,
	next_calendar_month as report_month ,
	0 AS total_revenue,
	previous_calendar_month,
	next_calendar_month,
	first_payment_month,
	previous_paid_month,
	previous_paid_month_revenue,
	next_paid_month,
	next_paid_month_revenue,
	0 AS new_mrr,
	0 AS expansion_revenue,
	0 AS contraction_revenue,
	0 AS back_from_churn_revenue,
	-(total_revenue) AS churned_revenue,
	gpu.game_name, 
	gpu.language, 
	gpu.has_older_device_model,
	gpu.age
FROM metrics m
LEFT JOIN games_paid_users gpu ON m.user_id=gpu.user_id
WHERE next_paid_month is NULL OR next_paid_month > next_calendar_month
),
monthly_summary AS (
    SELECT
        report_month,
        SUM(total_revenue) AS current_mrr,
        SUM(new_mrr) AS new_mrr,
        SUM(expansion_revenue) AS expansion_revenue,
        SUM(contraction_revenue) AS contraction_revenue,
        SUM(back_from_churn_revenue) AS back_from_churn_revenue,
        SUM(churned_revenue) AS churned_revenue
    FROM final_table
    GROUP BY 1
),

monthly_with_previous AS (
    SELECT
        *,
        LAG(current_mrr) OVER (ORDER BY report_month) AS previous_mrr
    FROM monthly_summary
)
SELECT
    report_month,
    previous_mrr,
    current_mrr,

    current_mrr - previous_mrr AS actual_change,

    new_mrr
    + expansion_revenue
    + contraction_revenue
    + back_from_churn_revenue
    + churned_revenue AS net_movement,

    (current_mrr - previous_mrr)
    - (
        new_mrr
        + expansion_revenue
        + contraction_revenue
        + back_from_churn_revenue
        + churned_revenue
      ) AS reconciliation_error,new_mrr,
    expansion_revenue,
    contraction_revenue,
    back_from_churn_revenue,
    churned_revenue

FROM monthly_with_previous
WHERE previous_mrr IS NOT NULL
ORDER BY report_month;