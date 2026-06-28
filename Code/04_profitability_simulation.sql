/* ================================================================
   FINTECH LENDING ANALYTICS — MODULE 4: PROFITABILITY
                                WHAT-IF SIMULATION
   ================================================================
   Project   : LendingClub Credit Analytics Platform
   Database  : PostgreSQL 13+
   Depends on: 01_data_model.sql  (run first)
               03_credit_approval_engine.sql  (for credit_decisions)

   What this file builds:
     View  1 — whatif_simulation  (7 DTI threshold scenarios)
     Query 2 — Read and interpret simulation results
     Query 3 — Break-even threshold analysis
     Query 4 — Grade-level profitability
     View  5 — tableau_whatif  (feeds Dashboard 4)

   How the simulation works:
     Tests 7 DTI approval thresholds (25% → 40%) in a single
     query using UNION ALL + CROSS JOIN. For each threshold,
     calculates: approved volume, default rate, interest income,
     credit losses, and net income.

     Business question answered:
     "If we tightened our DTI cutoff from 35% to 28%, how
      many fewer loans would we approve, what would our default
      rate look like, and would we earn more or less money?"
================================================================ */


/* ================================================================
   VIEW 1 — WHATIF SIMULATION
   ----------------------------------------------------------------
   Core mechanics:

   1. base CTE — pulls the 5 columns needed per loan
      (only closed loans with known outcomes)

   2. thresholds CTE — a 7-row table built with UNION ALL.
      SQL has no loops so UNION ALL is the equivalent of
      writing the values you'd put in a Python for-loop.

   3. CROSS JOIN — combines every threshold with every loan.
      Creates a (7 × loan_count) intermediate result.
      Each loan is evaluated against every threshold.

   4. CASE WHEN b.dti <= t.dti_limit — asks per row:
      "would this loan have been approved at this threshold?"

   5. GROUP BY t.dti_limit — collapses back to 7 summary rows.

   Column definitions:
     approved_loans    — loans that would have passed threshold
     approval_rate_pct — approved / total closed loans
     default_rate_pct  — default rate among approved loans only
                         (AVG ignores NULLs from declined loans)
     interest_income_M — total interest collected from approved
     loss_M            — net principal loss from approved defaults
     net_income_M      — interest_income_M minus loss_M
================================================================ */

CREATE OR REPLACE VIEW whatif_simulation AS
WITH base AS (
    SELECT
        l.funded_amnt,
        l.is_default,
        r.total_rec_int,
        r.net_loss,
        c.dti
    FROM fact_loans         l
    JOIN fact_repayments    r ON l.id = r.id
    JOIN dim_credit_history c ON l.id = c.id
    WHERE l.is_closed = 1        -- completed loans only
),
thresholds(dti_limit) AS (
    -- 7 scenarios tested simultaneously
    SELECT 25 UNION ALL
    SELECT 28 UNION ALL
    SELECT 30 UNION ALL
    SELECT 32 UNION ALL
    SELECT 35 UNION ALL
    SELECT 38 UNION ALL
    SELECT 40
)
SELECT
    t.dti_limit                                              AS dti_threshold,

    -- how many loans would be approved at this threshold
    SUM(CASE WHEN b.dti <= t.dti_limit
             THEN 1 ELSE 0 END)                             AS approved_loans,

    -- what percentage of all closed loans that represents
    ROUND(
        SUM(CASE WHEN b.dti <= t.dti_limit THEN 1 ELSE 0 END)
        * 100.0 / COUNT(*)
    , 1)                                                     AS approval_rate_pct,

    -- default rate ONLY among loans that would have been approved
    -- AVG() ignores the NULLs from declined loans automatically
    ROUND(
        AVG(CASE WHEN b.dti <= t.dti_limit
                 THEN b.is_default END) * 100
    , 2)                                                     AS default_rate_pct,

    -- total interest collected from approved borrowers who paid
    ROUND(
        SUM(CASE WHEN b.dti <= t.dti_limit
                 THEN b.total_rec_int ELSE 0 END) / 1e6
    , 2)                                                     AS interest_income_M,

    -- principal lost to defaults among approved loans
    ROUND(
        SUM(CASE WHEN b.dti <= t.dti_limit AND b.is_default = 1
                 THEN b.net_loss ELSE 0 END) / 1e6
    , 2)                                                     AS loss_M,

    -- bottom line: interest earned minus principal lost
    ROUND(
        SUM(CASE WHEN b.dti <= t.dti_limit
                 THEN b.total_rec_int ELSE 0 END) / 1e6
      - SUM(CASE WHEN b.dti <= t.dti_limit AND b.is_default = 1
                 THEN b.net_loss ELSE 0 END) / 1e6
    , 2)                                                     AS net_income_M

FROM thresholds t
CROSS JOIN base b
GROUP BY t.dti_limit
ORDER BY t.dti_limit;


/* ================================================================
   QUERY 2 — READ AND INTERPRET SIMULATION RESULTS
   ----------------------------------------------------------------
   Adds marginal_income_M: the additional net income you gain
   by loosening the threshold one step vs the previous threshold.
   When this turns negative, loosening further destroys value.
================================================================ */

SELECT
    dti_threshold,
    approved_loans,
    approval_rate_pct,
    default_rate_pct,
    interest_income_M,
    loss_M,
    net_income_M,
    -- change in net income vs previous threshold
    ROUND(
        net_income_M - LAG(net_income_M) OVER (ORDER BY dti_threshold)
    , 2)                                                    AS marginal_income_M,
    -- change in default rate vs previous threshold
    ROUND(
        default_rate_pct - LAG(default_rate_pct) OVER (ORDER BY dti_threshold)
    , 2)                                                    AS default_rate_change
FROM whatif_simulation
ORDER BY dti_threshold;


/* ================================================================
   QUERY 3 — BREAK-EVEN ANALYSIS
   ----------------------------------------------------------------
   Finds the threshold where net income is maximised and
   where marginal income first turns negative (the point of
   diminishing returns on loosening the DTI threshold).
================================================================ */

WITH sim AS (
    SELECT
        dti_threshold,
        net_income_M,
        default_rate_pct,
        approved_loans,
        ROUND(
            net_income_M - LAG(net_income_M) OVER (ORDER BY dti_threshold)
        , 2) AS marginal_income_M
    FROM whatif_simulation
)
SELECT
    dti_threshold,
    net_income_M,
    default_rate_pct,
    approved_loans,
    marginal_income_M,
    CASE
        WHEN net_income_M = MAX(net_income_M) OVER ()
             THEN 'OPTIMAL THRESHOLD'
        WHEN marginal_income_M < 0
             THEN 'DIMINISHING RETURNS'
        ELSE ''
    END AS flag
FROM sim
ORDER BY dti_threshold;


/* ================================================================
   QUERY 4 — GRADE-LEVEL PROFITABILITY
   ----------------------------------------------------------------
   Breaks down interest income vs losses by loan grade.
   Shows which grades are net contributors to profit and
   which destroy value even after interest income.
   Use this alongside the simulation to decide not just
   the DTI threshold but which grades to target.
================================================================ */

SELECT
    l.grade,
    COUNT(*)                                              AS loans,
    ROUND(AVG(l.is_default) * 100, 2)                   AS default_rate_pct,
    ROUND(SUM(l.funded_amnt)      / 1e6, 2)             AS portfolio_M,
    ROUND(SUM(r.total_rec_int)    / 1e6, 2)             AS interest_income_M,
    ROUND(SUM(r.net_loss)         / 1e6, 2)             AS loss_M,
    ROUND((SUM(r.total_rec_int) - SUM(r.net_loss)) / 1e6, 2)
                                                          AS net_income_M,
    -- return on portfolio: net income as % of portfolio deployed
    ROUND(
        (SUM(r.total_rec_int) - SUM(r.net_loss))
        / NULLIF(SUM(l.funded_amnt), 0) * 100
    , 2)                                                  AS return_on_portfolio_pct
FROM fact_loans      l
JOIN fact_repayments r ON l.id = r.id
WHERE l.is_closed = 1
GROUP BY l.grade
ORDER BY l.grade;


/* ================================================================
   VIEW 5 — TABLEAU EXPORT (DASHBOARD 4: WHAT-IF SIMULATION)
   ----------------------------------------------------------------
   Simple pass-through of whatif_simulation for Tableau.

   In Tableau Desktop, build an interactive version:
   1. Create a Parameter:
        Name: DTI Threshold
        Type: Integer, Min: 25, Max: 40, Step: 1
   2. Create a calculated field:
        Name: Meets Threshold
        Formula: [Dti] <= [DTI Threshold]
   3. Use [Meets Threshold] as a filter on tableau_portfolio
   4. Right-click the Parameter → Show Parameter Control
   The dashboard now updates live as you drag the slider.
================================================================ */

CREATE OR REPLACE VIEW tableau_whatif AS
SELECT * FROM whatif_simulation;


/* ================================================================
   VERIFICATION QUERIES
================================================================ */

-- Full simulation output
SELECT * FROM whatif_simulation;

-- Net income should generally increase as threshold rises
-- but default rate should also rise — confirm the trade-off exists
SELECT
    dti_threshold,
    net_income_M,
    default_rate_pct,
    CASE
        WHEN net_income_M > LAG(net_income_M) OVER (ORDER BY dti_threshold)
             THEN 'Higher net income'
        ELSE 'Lower net income'
    END AS vs_prev_threshold
FROM tableau_whatif
ORDER BY dti_threshold;

-- Grade profitability — confirm Grade A has highest return on portfolio
SELECT grade, return_on_portfolio_pct
FROM (
    SELECT
        l.grade,
        ROUND(
            (SUM(r.total_rec_int) - SUM(r.net_loss))
            / NULLIF(SUM(l.funded_amnt), 0) * 100
        , 2) AS return_on_portfolio_pct
    FROM fact_loans      l
    JOIN fact_repayments r ON l.id = r.id
    WHERE l.is_closed = 1
    GROUP BY l.grade
) g
ORDER BY grade;
