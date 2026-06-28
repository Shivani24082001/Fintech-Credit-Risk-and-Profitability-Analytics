/* ================================================================
   FINTECH LENDING ANALYTICS — MODULE 3: CREDIT APPROVAL
                                RULES ENGINE
   ================================================================
   Project   : LendingClub Credit Analytics Platform
   Database  : PostgreSQL 13+
   Depends on: 01_data_model.sql (run that first)

   What this file builds:
     View  1 — credit_decisions  (7-signal approval engine)
     Query 2 — Approval decision summary with validation
     Query 3 — Approval funnel by grade
     Query 4 — Income × decision analysis
     Query 5 — LTI distribution per decision bucket
     View  6 — tableau_approval  (feeds Dashboard 3)

   The 7 signals evaluated per application:
     1. fico_avg       — credit quality score
     2. dti            — debt burden ratio
     3. delinq_2yrs    — recent late payment count
     4. pub_rec        — bankruptcies / court judgments
     5. revol_util     — revolving credit utilisation %
     6. credit_age_yrs — length of credit history
     7. annual_inc     — absolute income capacity

   Two derived ratios computed inside the view:
     loan_to_income (LTI)      = funded_amnt / annual_inc
     payment_to_income (PTI)   = (installment × 12) / annual_inc
================================================================ */


/* ================================================================
   VIEW 1 — CREDIT DECISIONS
   ----------------------------------------------------------------
   Assigns every loan application to one of four buckets:

     APPROVE — STANDARD    clean profile across all 7 signals
     APPROVE — RESTRICTED  acceptable but one soft flag present
                           → 70–85% of requested credit limit
     REVIEW                borderline on multiple signals,
                           needs human underwriter check
     DECLINE               any single hard disqualifier present

   CASE evaluates top → bottom and stops at the first match.
   Hard declines are checked first so they cannot be overridden
   by a later APPROVE condition.

   Credit limit logic: income acts as a hard ceiling regardless
   of FICO quality. A low-income borrower cannot access the full
   loan amount even with a 780 credit score.
================================================================ */

CREATE OR REPLACE VIEW credit_decisions AS
SELECT
    l.id,
    l.grade,
    l.funded_amnt,
    l.int_rate,
    l.installment,
    l.is_default,
    c.fico_avg,
    c.dti,
    c.delinq_2yrs,
    c.pub_rec,
    c.revol_util,
    c.credit_age_yrs,
    c.collections,
    cu.annual_inc,
    cu.income_band,

    /* ── DERIVED RISK RATIOS ──────────────────────────────── */

    -- Loan-to-Income: loan size as fraction of annual income
    -- LTI > 0.60 means borrowing more than 60% of annual income
    ROUND(l.funded_amnt / NULLIF(cu.annual_inc, 0), 2)
        AS loan_to_income,

    -- Payment-to-Income: what % of annual income does this
    -- single loan consume in yearly payments
    ROUND((l.installment * 12) / NULLIF(cu.annual_inc, 0) * 100, 1)
        AS payment_to_income_pct,

    /* ── DECISION LOGIC ──────────────────────────────────── */
    CASE
        /* ── HARD DECLINES ──────────────────────────────── */

        -- Credit quality disqualifiers
        WHEN c.fico_avg        <  580  THEN 'DECLINE'
        WHEN c.delinq_2yrs     >= 3    THEN 'DECLINE'
        WHEN c.pub_rec         >= 2    THEN 'DECLINE'
        WHEN c.collections     >= 2    THEN 'DECLINE'
        WHEN c.revol_util      >= 95   THEN 'DECLINE'

        -- Debt burden disqualifier
        WHEN c.dti             >  40   THEN 'DECLINE'

        -- Income floor: too low to service any new debt
        WHEN cu.annual_inc     < 20000 THEN 'DECLINE'

        -- Loan size disqualifier: >60% of annual income
        WHEN l.funded_amnt / NULLIF(cu.annual_inc, 0) > 0.60
             THEN 'DECLINE'

        -- Combined income + DTI stress
        WHEN cu.annual_inc < 35000
             AND c.dti > 30             THEN 'DECLINE'

        /* ── REVIEW ─────────────────────────────────────── */

        -- Borderline credit quality
        WHEN c.fico_avg BETWEEN 580 AND 649   THEN 'REVIEW'
        WHEN c.dti      BETWEEN 35  AND 40    THEN 'REVIEW'
        WHEN c.delinq_2yrs = 2                THEN 'REVIEW'
        WHEN c.pub_rec = 1
             AND c.fico_avg < 680             THEN 'REVIEW'
        WHEN c.revol_util BETWEEN 80 AND 94
             AND c.dti > 30                   THEN 'REVIEW'
        WHEN c.credit_age_yrs < 2             THEN 'REVIEW'

        -- Income stress: low earner with moderate debt burden
        WHEN cu.annual_inc BETWEEN 20000 AND 35000
             AND c.dti > 25                   THEN 'REVIEW'

        -- Loan is 45–60% of annual income
        WHEN l.funded_amnt / NULLIF(cu.annual_inc, 0)
             BETWEEN 0.45 AND 0.60            THEN 'REVIEW'

        -- Single loan consumes >20% of annual income in payments
        WHEN (l.installment * 12) / NULLIF(cu.annual_inc, 0)
             > 0.20                           THEN 'REVIEW'

        -- Income-adjusted DTI: low earners get stricter cutoff
        WHEN cu.annual_inc < 50000
             AND c.dti BETWEEN 28 AND 35      THEN 'REVIEW'

        /* ── APPROVE — RESTRICTED ────────────────────────── */

        -- One soft flag present in any signal
        WHEN c.fico_avg       BETWEEN 650 AND 699 THEN 'APPROVE — RESTRICTED'
        WHEN c.dti            BETWEEN 28  AND 35  THEN 'APPROVE — RESTRICTED'
        WHEN c.revol_util     BETWEEN 60  AND 79  THEN 'APPROVE — RESTRICTED'
        WHEN c.credit_age_yrs BETWEEN 2   AND 4   THEN 'APPROVE — RESTRICTED'
        WHEN cu.income_band = '1. <$30K'           THEN 'APPROVE — RESTRICTED'
        WHEN l.funded_amnt / NULLIF(cu.annual_inc, 0)
             BETWEEN 0.30 AND 0.44             THEN 'APPROVE — RESTRICTED'

        /* ── APPROVE — STANDARD ──────────────────────────── */
        ELSE 'APPROVE — STANDARD'
    END AS decision,

    /* ── CREDIT LIMIT ────────────────────────────────────────
       Income is a hard ceiling regardless of FICO.
       A low-income borrower is capped at 40% of requested
       amount even with an excellent credit score.          */
    CASE
        -- Premium: strong credit + income + low utilisation
        WHEN c.fico_avg    >= 750
             AND c.dti     <= 20
             AND c.revol_util  <= 30
             AND cu.annual_inc >= 80000
             THEN ROUND(l.funded_amnt * 1.00, 0)

        -- Standard: good credit + adequate income
        WHEN c.fico_avg    >= 700
             AND c.dti     <= 28
             AND cu.annual_inc >= 50000
             THEN ROUND(l.funded_amnt * 0.85, 0)

        -- Restricted: acceptable credit, some income concern
        WHEN c.fico_avg    >= 650
             AND c.dti     <= 35
             AND cu.annual_inc >= 35000
             THEN ROUND(l.funded_amnt * 0.70, 0)

        -- Low income override: hard cap regardless of FICO
        WHEN cu.annual_inc < 35000
             THEN ROUND(l.funded_amnt * 0.40, 0)

        -- Default
        ELSE ROUND(l.funded_amnt * 0.50, 0)
    END AS approved_limit

FROM fact_loans         l
JOIN dim_credit_history c  ON l.id = c.id
JOIN dim_customer       cu ON l.id = cu.id;


/* ================================================================
   QUERY 2 — APPROVAL DECISION SUMMARY WITH VALIDATION
   ----------------------------------------------------------------
   Key validation: the staircase pattern must hold.
   actual_default_rate should increase from STANDARD → DECLINE.
   avg_income should decrease from STANDARD → DECLINE.
   avg_lti should increase from STANDARD → DECLINE.
   If this pattern breaks, the rules need recalibration.
================================================================ */

SELECT
    decision,
    COUNT(*)                                              AS applications,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER(), 1)   AS pct_of_total,
    ROUND(AVG(is_default)          * 100, 2)            AS actual_default_rate,
    ROUND(AVG(approved_limit),           0)             AS avg_approved_limit,
    ROUND(AVG(fico_avg),                 0)             AS avg_fico,
    ROUND(AVG(dti),                      1)             AS avg_dti,
    ROUND(AVG(annual_inc),               0)             AS avg_income,
    ROUND(AVG(loan_to_income),           2)             AS avg_lti,
    ROUND(AVG(payment_to_income_pct),    1)             AS avg_pti_pct
FROM credit_decisions
GROUP BY decision
ORDER BY
    CASE decision
        WHEN 'APPROVE — STANDARD'    THEN 1
        WHEN 'APPROVE — RESTRICTED'  THEN 2
        WHEN 'REVIEW'                THEN 3
        WHEN 'DECLINE'               THEN 4
    END;


/* ================================================================
   QUERY 3 — APPROVAL FUNNEL BY GRADE
   ----------------------------------------------------------------
   Shows how the rules engine treats each risk grade.
   Grade A should have the highest approval rate.
   Grade G should have the highest decline rate.
   This is also a business sanity check — if Grade A has a
   high decline rate, the income rules may be too strict.
================================================================ */

SELECT
    grade,
    COUNT(*)                                            AS total,
    SUM(CASE WHEN decision LIKE 'APPROVE%' THEN 1 ELSE 0 END) AS approved,
    SUM(CASE WHEN decision = 'REVIEW'      THEN 1 ELSE 0 END) AS review,
    SUM(CASE WHEN decision = 'DECLINE'     THEN 1 ELSE 0 END) AS declined,
    ROUND(
        SUM(CASE WHEN decision LIKE 'APPROVE%' THEN 1 ELSE 0 END)
        * 100.0 / COUNT(*), 1
    )                                                   AS approval_rate_pct,
    ROUND(AVG(fico_avg), 0)                            AS avg_fico,
    ROUND(AVG(annual_inc), 0)                          AS avg_income
FROM credit_decisions
GROUP BY grade
ORDER BY grade;


/* ================================================================
   QUERY 4 — INCOME × DECISION ANALYSIS
   ----------------------------------------------------------------
   Validates the income signal is working.
   Low income bands should concentrate in DECLINE / RESTRICTED.
   High income bands should concentrate in APPROVE STANDARD.
   If the distribution looks flat, the income rules may be
   too weak or the income band boundaries need adjusting.
================================================================ */

SELECT
    income_band,
    decision,
    COUNT(*)                                            AS applications,
    ROUND(COUNT(*) * 100.0 /
        SUM(COUNT(*)) OVER (PARTITION BY income_band), 1) AS pct_within_band,
    ROUND(AVG(is_default) * 100, 2)                   AS actual_default_rate,
    ROUND(AVG(loan_to_income), 2)                     AS avg_lti
FROM credit_decisions
GROUP BY income_band, decision
ORDER BY income_band, decision;


/* ================================================================
   QUERY 5 — LTI DISTRIBUTION PER DECISION BUCKET
   ----------------------------------------------------------------
   loan_to_income (LTI) should be highest for DECLINE and
   lowest for APPROVE STANDARD. This query shows the spread
   of LTI values within each bucket to confirm the income
   signal is differentiating borrowers correctly.
================================================================ */

SELECT
    decision,
    ROUND(MIN(loan_to_income),  2)                     AS min_lti,
    ROUND(AVG(loan_to_income),  2)                     AS avg_lti,
    ROUND(MAX(loan_to_income),  2)                     AS max_lti,
    ROUND(MIN(payment_to_income_pct), 1)               AS min_pti_pct,
    ROUND(AVG(payment_to_income_pct), 1)               AS avg_pti_pct,
    ROUND(MAX(payment_to_income_pct), 1)               AS max_pti_pct
FROM credit_decisions
GROUP BY decision
ORDER BY
    CASE decision
        WHEN 'APPROVE — STANDARD'    THEN 1
        WHEN 'APPROVE — RESTRICTED'  THEN 2
        WHEN 'REVIEW'                THEN 3
        WHEN 'DECLINE'               THEN 4
    END;


/* ================================================================
   VIEW 6 — TABLEAU EXPORT (DASHBOARD 3: CREDIT APPROVAL ENGINE)
   ----------------------------------------------------------------
   Exposes all 7 signals, both derived ratios, the decision,
   and the approved limit. In Tableau:
     - Decision → pie chart (application breakdown)
     - FICO Avg vs Loan To Income → scatter coloured by Decision
     - Income Band × Decision → heatmap (validates income signal)
     - Default Rate by Decision → bar (validates engine accuracy)
================================================================ */

CREATE OR REPLACE VIEW tableau_approval AS
SELECT
    id,
    grade,
    funded_amnt,
    int_rate,
    installment,
    is_default,
    fico_avg,
    dti,
    delinq_2yrs,
    pub_rec,
    revol_util,
    credit_age_yrs,
    collections,
    annual_inc,
    income_band,
    loan_to_income,
    payment_to_income_pct,
    decision,
    approved_limit,
    funded_amnt - approved_limit                        AS limit_reduction,
    CASE WHEN decision LIKE 'APPROVE%'
         THEN 1 ELSE 0 END                             AS is_approved
FROM credit_decisions;


/* ================================================================
   VERIFICATION QUERIES
================================================================ */

-- Staircase check: default rate must increase STANDARD → DECLINE
SELECT decision,
       ROUND(AVG(is_default) * 100, 2) AS actual_default_rate,
       COUNT(*)                         AS applications
FROM   credit_decisions
GROUP  BY decision
ORDER  BY actual_default_rate ASC;

-- Income signal check: avg income must decrease STANDARD → DECLINE
SELECT decision,
       ROUND(AVG(annual_inc), 0) AS avg_income,
       ROUND(AVG(fico_avg),   0) AS avg_fico
FROM   credit_decisions
GROUP  BY decision
ORDER  BY avg_income DESC;
