/* ================================================================
   FINTECH LENDING ANALYTICS — MODULE 2: RISK ANALYTICS
                                & CUSTOMER SEGMENTATION
   ================================================================
   Project   : LendingClub Credit Analytics Platform
   Database  : PostgreSQL 13+
   Depends on: 01_data_model.sql (run that first)

   What this file builds:
     Queries  1 — Default rate & portfolio exposure by grade
     Query    2 — Repayment behavior by income band
     Query    3 — FICO × Grade default rate heatmap
     Query    4 — Default exposure by loan purpose
     Query    5 — Geographic risk by state
     View     6 — borrower_segments (risk tier + value tier)
     Query    7 — Segment performance summary
     View     8 — tableau_risk (feeds Dashboard 2)
================================================================ */


/* ================================================================
   QUERY 1 — DEFAULT RATE & PORTFOLIO EXPOSURE BY GRADE
   ----------------------------------------------------------------
   Grade runs A (safest) → G (riskiest).
   Shows the core trade-off: higher grade = lower default rate
   but also lower interest rate. Portfolio managers use this
   to balance yield against credit loss.
================================================================ */

SELECT
    l.grade,
    COUNT(*)                                        AS total_loans,
    SUM(l.is_default)                               AS total_defaults,
    ROUND(AVG(l.is_default) * 100, 2)              AS default_rate_pct,
    ROUND(SUM(l.funded_amnt)   / 1e6, 2)           AS portfolio_M,
    ROUND(SUM(r.net_loss)      / 1e6, 2)           AS total_loss_M,
    ROUND(SUM(r.total_rec_int) / 1e6, 2)           AS interest_earned_M,
    -- net contribution = interest earned minus losses
    ROUND((SUM(r.total_rec_int) - SUM(r.net_loss)) / 1e6, 2) AS net_contribution_M,
    ROUND(AVG(l.int_rate), 2)                      AS avg_int_rate,
    ROUND(AVG(c.fico_avg), 0)                      AS avg_fico,
    ROUND(AVG(c.dti),      1)                      AS avg_dti
FROM fact_loans         l
JOIN dim_credit_history c ON l.id = c.id
JOIN fact_repayments    r ON l.id = r.id
WHERE l.is_closed = 1          -- completed loans only (known outcomes)
GROUP BY l.grade
ORDER BY l.grade;


/* ================================================================
   QUERY 2 — REPAYMENT BEHAVIOR BY INCOME BAND
   ----------------------------------------------------------------
   repayment_ratio = total_pymnt / funded_amnt
   A ratio of 1.0 means the principal was fully repaid.
   Below 1.0 means the borrower stopped paying before full repayment.
   Segments borrowers by income to show absolute income capacity
   independent of DTI ratio.
================================================================ */

SELECT
    cu.income_band,
    COUNT(*)                                        AS loans,
    ROUND(AVG(r.repayment_ratio) * 100, 1)         AS avg_repayment_pct,
    ROUND(AVG(l.is_default)      * 100, 2)         AS default_rate_pct,
    ROUND(AVG(l.int_rate),             2)          AS avg_int_rate,
    ROUND(SUM(r.total_rec_int) / 1e6,  2)         AS interest_earned_M,
    ROUND(SUM(r.net_loss)      / 1e6,  2)         AS total_loss_M
FROM fact_loans      l
JOIN fact_repayments r  ON l.id = r.id
JOIN dim_customer    cu ON l.id = cu.id
WHERE l.is_closed = 1
  AND cu.income_band IS NOT NULL
GROUP BY cu.income_band
ORDER BY cu.income_band;


/* ================================================================
   QUERY 3 — FICO × GRADE DEFAULT RATE HEATMAP
   ----------------------------------------------------------------
   Cross-tabulates credit quality (FICO band) against loan risk
   tier (grade) to show which combinations produce the highest
   default rates. In Tableau this becomes a colour-coded matrix.
   Numbered prefixes on fico_band ensure correct sort order.
================================================================ */

SELECT
    c.fico_band,
    l.grade,
    COUNT(*)                                        AS loans,
    ROUND(AVG(l.is_default) * 100, 2)             AS default_rate_pct,
    ROUND(AVG(l.int_rate),         2)              AS avg_int_rate,
    ROUND(AVG(c.dti),              1)              AS avg_dti,
    ROUND(SUM(l.funded_amnt) / 1e6, 1)            AS portfolio_M
FROM fact_loans         l
JOIN dim_credit_history c ON l.id = c.id
WHERE l.is_closed = 1
  AND c.fico_band IS NOT NULL
GROUP BY c.fico_band, l.grade
ORDER BY c.fico_band, l.grade;


/* ================================================================
   QUERY 4 — DEFAULT EXPOSURE BY LOAN PURPOSE
   ----------------------------------------------------------------
   Different loan purposes carry different risk profiles.
   Small business loans default more than debt consolidation.
   Useful for portfolio concentration analysis — too much
   exposure to one purpose increases correlated risk.
================================================================ */

SELECT
    l.purpose,
    COUNT(*)                                        AS total_loans,
    ROUND(AVG(l.is_default)    * 100, 2)           AS default_rate_pct,
    ROUND(SUM(l.funded_amnt)   / 1e6, 1)           AS portfolio_M,
    ROUND(SUM(r.net_loss)      / 1e6, 2)           AS total_loss_M,
    ROUND(AVG(l.int_rate),           2)            AS avg_int_rate,
    ROUND(AVG(c.fico_avg),           0)            AS avg_fico
FROM fact_loans         l
JOIN fact_repayments    r ON l.id = r.id
JOIN dim_credit_history c ON l.id = c.id
WHERE l.is_closed = 1
GROUP BY l.purpose
ORDER BY total_loans DESC;


/* ================================================================
   QUERY 5 — GEOGRAPHIC RISK BY STATE
   ----------------------------------------------------------------
   State-level risk concentration. In Tableau this connects
   to a filled map chart using the two-letter state code.
   HAVING COUNT(*) >= 100 removes states with too few loans
   to produce statistically meaningful default rates.
================================================================ */

SELECT
    cu.addr_state                                   AS state,
    COUNT(*)                                        AS total_loans,
    ROUND(AVG(l.is_default) * 100, 2)             AS default_rate_pct,
    ROUND(SUM(l.funded_amnt) / 1e6, 1)            AS portfolio_M,
    ROUND(SUM(r.net_loss)    / 1e6, 2)            AS total_loss_M,
    ROUND(AVG(c.fico_avg),         0)              AS avg_fico,
    ROUND(AVG(c.dti),              1)              AS avg_dti,
    ROUND(AVG(l.int_rate),         2)              AS avg_int_rate
FROM fact_loans         l
JOIN dim_customer       cu ON l.id = cu.id
JOIN dim_credit_history c  ON l.id = c.id
JOIN fact_repayments    r  ON l.id = r.id
WHERE l.is_closed = 1
GROUP BY cu.addr_state
HAVING COUNT(*) >= 100
ORDER BY default_rate_pct DESC;


/* ================================================================
   VIEW 6 — BORROWER SEGMENTS
   ----------------------------------------------------------------
   Classifies every borrower on two independent axes:

   Risk Tier  — how likely are they to default?
     1. Prime         : FICO ≥ 740, DTI < 20, zero delinquencies
     2. Near-Prime    : FICO ≥ 680, DTI < 30, ≤1 delinquency
     3. Sub-Prime     : FICO ≥ 620, DTI < 40
     4. Deep Sub-Prime: everyone else

   Value Tier — how much revenue will they generate?
     A. High-Value : income ≥ $100K, loan ≥ $15K
     B. Mid-Value  : income ≥ $60K,  loan ≥ $8K
     C. Low-Value  : everyone else

   Combining the two tiers creates 12 distinct segments.
   The strategic focus is Prime + High-Value: lowest default
   risk, highest interest income.
================================================================ */

CREATE OR REPLACE VIEW borrower_segments AS
SELECT
    l.id,
    l.grade,
    l.funded_amnt,
    l.int_rate,
    l.is_default,
    c.fico_avg,
    c.dti,
    c.delinq_2yrs,
    c.revol_util,
    cu.annual_inc,
    cu.income_band,

    CASE
        WHEN c.fico_avg >= 740 AND c.dti < 20 AND c.delinq_2yrs = 0
             THEN '1. Prime'
        WHEN c.fico_avg >= 680 AND c.dti < 30 AND c.delinq_2yrs <= 1
             THEN '2. Near-Prime'
        WHEN c.fico_avg >= 620 AND c.dti < 40
             THEN '3. Sub-Prime'
        ELSE      '4. Deep Sub-Prime'
    END AS risk_tier,

    CASE
        WHEN cu.annual_inc >= 100000 AND l.funded_amnt >= 15000
             THEN 'A. High-Value'
        WHEN cu.annual_inc >= 60000  AND l.funded_amnt >= 8000
             THEN 'B. Mid-Value'
        ELSE      'C. Low-Value'
    END AS value_tier

FROM fact_loans         l
JOIN dim_credit_history c  ON l.id = c.id
JOIN dim_customer       cu ON l.id = cu.id;


/* ================================================================
   QUERY 7 — SEGMENT PERFORMANCE SUMMARY
   ----------------------------------------------------------------
   Aggregates the 12 borrower segments.
   Expected pattern: as risk_tier worsens (1→4) default_rate rises.
   As value_tier worsens (A→C) avg_loan_size and avg_income fall.
================================================================ */

SELECT
    risk_tier,
    value_tier,
    COUNT(*)                                        AS borrowers,
    ROUND(AVG(is_default) * 100, 2)               AS default_rate_pct,
    ROUND(AVG(funded_amnt),      0)               AS avg_loan_size,
    ROUND(AVG(annual_inc),       0)               AS avg_income,
    ROUND(AVG(fico_avg),         0)               AS avg_fico,
    ROUND(AVG(dti),              1)               AS avg_dti,
    ROUND(AVG(int_rate),         2)               AS avg_int_rate
FROM borrower_segments
GROUP BY risk_tier, value_tier
ORDER BY risk_tier, value_tier;


/* ================================================================
   VIEW 8 — TABLEAU EXPORT (DASHBOARD 2: RISK HEATMAP)
   ----------------------------------------------------------------
   Pre-joined single-row-per-loan view with all fields needed
   for the risk heatmap, scatter, and income band charts.
   Restricted to closed loans only for accurate default rates.
================================================================ */

CREATE OR REPLACE VIEW tableau_risk AS
SELECT
    l.id,
    l.grade,
    l.int_rate,
    l.funded_amnt,
    l.is_default,
    l.is_closed,
    l.purpose,
    c.fico_avg,
    c.fico_band,
    c.dti,
    c.dti_band,
    c.delinq_2yrs,
    c.pub_rec,
    c.revol_util,
    c.credit_age_yrs,
    cu.income_band,
    cu.annual_inc,
    cu.addr_state,
    r.repayment_ratio,
    r.net_loss,
    r.total_rec_int,
    -- pre-computed fields for faster Tableau rendering
    CASE WHEN l.is_default = 1
         THEN l.funded_amnt ELSE 0 END             AS default_exposure,
    l.funded_amnt * (l.int_rate / 100)             AS annual_interest_est
FROM fact_loans         l
JOIN dim_credit_history c  ON l.id = c.id
JOIN dim_customer       cu ON l.id = cu.id
JOIN fact_repayments    r  ON l.id = r.id
WHERE l.is_closed = 1;


/* ================================================================
   TABLEAU VIEW — GEOGRAPHIC RISK MAP (DASHBOARD 5)
   ----------------------------------------------------------------
   Pre-aggregated to state level. Connect Tableau to this view,
   drag addr_state to the map canvas — Tableau auto-geocodes
   US two-letter state codes to filled polygon shapes.
================================================================ */

CREATE OR REPLACE VIEW tableau_geo AS
SELECT
    cu.addr_state                                   AS state,
    COUNT(*)                                        AS total_loans,
    ROUND(AVG(l.is_default) * 100, 2)             AS default_rate_pct,
    ROUND(SUM(l.funded_amnt) / 1e6, 1)            AS portfolio_M,
    ROUND(SUM(r.net_loss)    / 1e6, 2)            AS loss_M,
    ROUND(AVG(c.fico_avg),         0)              AS avg_fico,
    ROUND(AVG(c.dti),              1)              AS avg_dti,
    ROUND(AVG(l.int_rate),         2)              AS avg_int_rate
FROM fact_loans         l
JOIN dim_customer       cu ON l.id = cu.id
JOIN dim_credit_history c  ON l.id = c.id
JOIN fact_repayments    r  ON l.id = r.id
WHERE l.is_closed = 1
GROUP BY cu.addr_state
HAVING COUNT(*) >= 50;


/* ================================================================
   VERIFICATION QUERIES
================================================================ */

-- Confirm segment view created
SELECT risk_tier, value_tier, COUNT(*) AS borrowers
FROM   borrower_segments
GROUP  BY risk_tier, value_tier
ORDER  BY risk_tier, value_tier;

-- Top 5 states by default rate
SELECT state, default_rate_pct, portfolio_M
FROM   tableau_geo
ORDER  BY default_rate_pct DESC
LIMIT  5;
