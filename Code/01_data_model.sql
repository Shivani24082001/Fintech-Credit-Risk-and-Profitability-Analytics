/* ================================================================
   FINTECH LENDING ANALYTICS — MODULE 1: DATA MODEL
   ================================================================
   Project   : LendingClub Credit Analytics Platform
   Database  : PostgreSQL 13+
   Dataset   : https://www.kaggle.com/datasets/wordsforthewise/lending-club
   File      : accepted_2007_to_2018q4.csv

   What this file builds:
     1. loans_raw          — staging table (raw CSV data, untouched)
     2. cleaned_loans      — view: type conversions, null fills,
                             outlier caps, feature engineering
     3. dim_customer       — who is the borrower?
     4. fact_loans         — what loan did they get?
     5. fact_repayments    — what happened when they paid?
     6. dim_credit_history — how creditworthy were they?

   Run order: this file first, before all other modules.
================================================================ */


/* ================================================================
   SECTION 1 — RAW STAGING TABLE
   Mirrors the CSV exactly. No transformations yet.
   All "messy" columns (int_rate, term, dates) kept as TEXT
   so the load doesn't fail on format mismatches.
================================================================ */

DROP TABLE IF EXISTS loans_raw CASCADE;

CREATE TABLE loans_raw (
    id                          TEXT,
    loan_amnt                   NUMERIC,
    funded_amnt                 NUMERIC,
    term                        TEXT,        -- " 36 months"
    int_rate                    TEXT,        -- "15.27%"
    installment                 NUMERIC,
    grade                       TEXT,
    sub_grade                   TEXT,
    emp_length                  TEXT,        -- "10+ years"
    home_ownership              TEXT,
    annual_inc                  NUMERIC,
    verification_status         TEXT,
    issue_d                     TEXT,        -- "Jan-2015"
    loan_status                 TEXT,
    purpose                     TEXT,
    addr_state                  TEXT,
    dti                         NUMERIC,
    delinq_2yrs                 NUMERIC,
    earliest_cr_line            TEXT,        -- "Apr-2000"
    fico_range_low              NUMERIC,
    fico_range_high             NUMERIC,
    open_acc                    NUMERIC,
    pub_rec                     NUMERIC,
    revol_bal                   NUMERIC,
    revol_util                  TEXT,        -- "73.7%"
    total_acc                   NUMERIC,
    total_pymnt                 NUMERIC,
    total_rec_prncp             NUMERIC,
    total_rec_int               NUMERIC,
    recoveries                  NUMERIC,
    last_pymnt_amnt             NUMERIC,
    out_prncp                   NUMERIC,
    collections_12_mths_ex_med  NUMERIC
);

/*  Load the CSV — replace the path with your actual file location
    Run this in psql terminal (not pgAdmin):

    \COPY loans_raw
    FROM '/full/path/to/accepted_2007_to_2018q4.csv'
    CSV HEADER NULL '';

    Verify:
    SELECT COUNT(*) FROM loans_raw;          -- expect ~2,260,000
    SELECT loan_status, COUNT(*)
    FROM   loans_raw
    GROUP  BY loan_status
    ORDER  BY 2 DESC;
*/


/* ================================================================
   SECTION 2 — CLEANED_LOANS VIEW
   Fixes every data quality issue in the raw table:
     - Strips "%" from int_rate and revol_util → NUMERIC
     - Strips "months" from term → INTEGER
     - Maps emp_length text → numeric years
     - Parses "Mon-YYYY" strings → DATE
     - Fills NULLs with medians / safe defaults
     - Caps outliers (income, DTI, utilisation)
     - Engineers: fico_avg, credit_age_yrs, repayment_ratio,
                  net_loss, is_default, is_closed, and
                  income / FICO / DTI band labels
================================================================ */

CREATE OR REPLACE VIEW cleaned_loans AS
WITH typed AS (
    SELECT
        id,
        loan_amnt,
        funded_amnt,

        /* "  36 months" → 36 */
        CAST(TRIM(REPLACE(REPLACE(term, 'months', ''), ' ', ''))
             AS INTEGER)                                    AS term_months,

        /* "15.27%" → 15.27 */
        CAST(REPLACE(int_rate,   '%', '') AS NUMERIC)      AS int_rate,
        CAST(REPLACE(revol_util, '%', '') AS NUMERIC)      AS revol_util_raw,

        installment,
        grade,
        sub_grade,

        /* "10+ years" → 10 */
        CASE emp_length
            WHEN '< 1 year'  THEN 0
            WHEN '1 year'    THEN 1
            WHEN '2 years'   THEN 2
            WHEN '3 years'   THEN 3
            WHEN '4 years'   THEN 4
            WHEN '5 years'   THEN 5
            WHEN '6 years'   THEN 6
            WHEN '7 years'   THEN 7
            WHEN '8 years'   THEN 8
            WHEN '9 years'   THEN 9
            WHEN '10+ years' THEN 10
            ELSE 5                          -- median fallback
        END                                                 AS emp_length_yrs,

        home_ownership,

        /* cap income at $500K (99th-pct proxy) */
        LEAST(COALESCE(annual_inc, 60000), 500000)         AS annual_inc,

        verification_status,

        /* "Jan-2015" → date */
        TO_DATE(issue_d,          'Mon-YYYY')              AS issue_date,
        TO_DATE(earliest_cr_line, 'Mon-YYYY')              AS cr_line_date,

        loan_status,
        purpose,
        addr_state,

        /* fill NULLs */
        LEAST(COALESCE(dti,  20.0), 100.0)                 AS dti,
        COALESCE(delinq_2yrs,              0)              AS delinq_2yrs,
        COALESCE(open_acc,                10)              AS open_acc,
        COALESCE(pub_rec,                  0)              AS pub_rec,
        COALESCE(revol_bal,                0)              AS revol_bal,
        COALESCE(total_acc,               20)              AS total_acc,
        COALESCE(total_pymnt,              0)              AS total_pymnt,
        COALESCE(total_rec_prncp,          0)              AS total_rec_prncp,
        COALESCE(total_rec_int,            0)              AS total_rec_int,
        COALESCE(recoveries,               0)              AS recoveries,
        COALESCE(last_pymnt_amnt,          0)              AS last_pymnt_amnt,
        COALESCE(out_prncp,                0)              AS out_prncp,
        COALESCE(collections_12_mths_ex_med, 0)           AS collections,

        (fico_range_low + fico_range_high) / 2.0           AS fico_avg,
        fico_range_low,
        fico_range_high

    FROM loans_raw
    WHERE annual_inc     IS NOT NULL
      AND loan_status    IS NOT NULL
      AND grade          IS NOT NULL
      AND fico_range_low IS NOT NULL
)
SELECT
    *,

    /* cap revolving utilisation at 150% */
    LEAST(revol_util_raw, 150)                             AS revol_util,

    /* credit age: years between first credit line and loan issue */
    ROUND(
        EXTRACT(EPOCH FROM (issue_date - cr_line_date))
        / (365.25 * 86400)
    , 1)                                                   AS credit_age_yrs,

    /* repayment ratio: fraction of funded amount paid back */
    ROUND(total_pymnt / NULLIF(funded_amnt, 0), 4)         AS repayment_ratio,

    /* net loss: principal not recovered after default */
    GREATEST(funded_amnt - total_rec_prncp - recoveries, 0) AS net_loss,

    /* default flag: 1 = charged off or defaulted */
    CASE WHEN loan_status IN ('Charged Off', 'Default')
         THEN 1 ELSE 0 END                                 AS is_default,

    /* closed flag: 1 = loan has a known final outcome */
    CASE WHEN loan_status IN ('Fully Paid', 'Charged Off', 'Default')
         THEN 1 ELSE 0 END                                 AS is_closed,

    /* income band — numbered prefix forces correct Tableau sort order */
    CASE
        WHEN annual_inc <  30000  THEN '1. <$30K'
        WHEN annual_inc <  60000  THEN '2. $30–60K'
        WHEN annual_inc < 100000  THEN '3. $60–100K'
        WHEN annual_inc < 200000  THEN '4. $100–200K'
        ELSE                           '5. >$200K'
    END                                                    AS income_band,

    /* FICO band */
    CASE
        WHEN (fico_range_low + fico_range_high)/2 < 580 THEN '1. Poor <580'
        WHEN (fico_range_low + fico_range_high)/2 < 670 THEN '2. Fair 580–670'
        WHEN (fico_range_low + fico_range_high)/2 < 740 THEN '3. Good 670–740'
        WHEN (fico_range_low + fico_range_high)/2 < 800 THEN '4. Very Good 740–800'
        ELSE                                                  '5. Exceptional >800'
    END                                                    AS fico_band,

    /* DTI band */
    CASE
        WHEN dti < 15  THEN '1. <15%'
        WHEN dti < 25  THEN '2. 15–25%'
        WHEN dti < 35  THEN '3. 25–35%'
        WHEN dti < 50  THEN '4. 35–50%'
        ELSE               '5. >50%'
    END                                                    AS dti_band

FROM typed;


/* ================================================================
   SECTION 3 — FOUR ANALYTICAL VIEWS (DATA MODEL LAYERS)
   Each view is one logical business domain.
   All four join back to each other on: id
================================================================ */

/* Layer 1 — Who is the borrower? */
CREATE OR REPLACE VIEW dim_customer AS
SELECT
    id,
    annual_inc,
    emp_length_yrs,
    home_ownership,
    addr_state,
    verification_status,
    income_band
FROM cleaned_loans;


/* Layer 2 — What loan did they get? */
CREATE OR REPLACE VIEW fact_loans AS
SELECT
    id,
    loan_amnt,
    funded_amnt,
    term_months,
    int_rate,
    installment,
    grade,
    sub_grade,
    purpose,
    issue_date,
    loan_status,
    is_default,
    is_closed
FROM cleaned_loans;


/* Layer 3 — What happened when they had to pay? */
CREATE OR REPLACE VIEW fact_repayments AS
SELECT
    id,
    total_pymnt,
    total_rec_prncp,
    total_rec_int,
    recoveries,
    last_pymnt_amnt,
    out_prncp,
    repayment_ratio,
    net_loss
FROM cleaned_loans;


/* Layer 4 — How creditworthy were they? */
CREATE OR REPLACE VIEW dim_credit_history AS
SELECT
    id,
    fico_avg,
    fico_band,
    dti,
    dti_band,
    delinq_2yrs,
    open_acc,
    pub_rec,
    revol_bal,
    revol_util,
    total_acc,
    credit_age_yrs,
    collections
FROM cleaned_loans;


/* ================================================================
   SECTION 4 — TABLEAU EXPORT VIEW (DASHBOARD 1: PORTFOLIO OVERVIEW)
   Pre-joined, one row per loan, feeds Portfolio Overview dashboard.
================================================================ */

CREATE OR REPLACE VIEW tableau_portfolio AS
SELECT
    l.id,
    l.grade,
    l.sub_grade,
    l.funded_amnt,
    l.loan_amnt,
    l.int_rate,
    l.term_months,
    l.purpose,
    l.loan_status,
    l.is_default,
    l.is_closed,
    l.issue_date,
    DATE_PART('year',  l.issue_date)        AS issue_year,
    DATE_PART('month', l.issue_date)        AS issue_month,
    c.fico_avg,
    c.fico_band,
    c.dti,
    c.dti_band,
    c.delinq_2yrs,
    c.revol_util,
    r.total_pymnt,
    r.total_rec_int,
    r.repayment_ratio,
    r.net_loss,
    cu.annual_inc,
    cu.income_band,
    cu.addr_state,
    cu.home_ownership,
    cu.verification_status
FROM fact_loans         l
JOIN dim_credit_history c  ON l.id = c.id
JOIN fact_repayments    r  ON l.id = r.id
JOIN dim_customer       cu ON l.id = cu.id;


/* ================================================================
   VERIFICATION QUERIES — run after creating all objects
================================================================ */

-- Row counts per layer (should all match)
SELECT 'loans_raw'          AS layer, COUNT(*) AS rows FROM loans_raw
UNION ALL
SELECT 'cleaned_loans',               COUNT(*) FROM cleaned_loans
UNION ALL
SELECT 'fact_loans',                  COUNT(*) FROM fact_loans
UNION ALL
SELECT 'dim_customer',                COUNT(*) FROM dim_customer
UNION ALL
SELECT 'fact_repayments',             COUNT(*) FROM fact_repayments
UNION ALL
SELECT 'dim_credit_history',          COUNT(*) FROM dim_credit_history;

-- Default rate check
SELECT
    is_default,
    COUNT(*)                                        AS loans,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER(), 1) AS pct
FROM cleaned_loans
GROUP BY is_default;

-- Sample cleaned row
SELECT
    id, grade, int_rate, term_months, fico_avg,
    dti, income_band, fico_band, is_default, repayment_ratio
FROM cleaned_loans
LIMIT 5;
