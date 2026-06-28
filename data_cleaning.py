"""
=======================================================================
FINTECH LENDING ANALYTICS — DATA CLEANING
=======================================================================
Project   : LendingClub Credit Analytics Platform
File      : data_cleaning.py
Purpose   : Loads the raw LendingClub CSV, cleans every column,
            engineers derived features, and exports a clean CSV
            ready to load into PostgreSQL.

Workflow in the full project:
  1. Run this file  → produces  cleaned_loans.csv
  2. Load cleaned_loans.csv into PostgreSQL loans_raw table
  3. Run SQL files 01 → 04 for analytics

Dataset   : https://www.kaggle.com/datasets/wordsforthewise/lending-club
Input     : accepted_2007_to_2018q4.csv   (place in same folder)
Outputs   : cleaned_loans.csv             (load into PostgreSQL)
            data_quality_report.txt       (before/after summary)

Install   : pip install pandas numpy
=======================================================================
"""

import pandas as pd
import numpy as np
import warnings
import os
from datetime import datetime

warnings.filterwarnings("ignore")

# ── Configuration ──────────────────────────────────────────────────────
INPUT_FILE   = "accepted_2007_to_2018q4.csv"
OUTPUT_FILE  = "cleaned_loans.csv"
REPORT_FILE  = "data_quality_report.txt"
SAMPLE_ROWS  = None          # set to e.g. 200_000 for faster dev runs
                              # None = load the full 2.26M row dataset

DIVIDER = "=" * 65


# ══════════════════════════════════════════════════════════════════════
# STEP 1 — LOAD RAW DATA
# ══════════════════════════════════════════════════════════════════════

def load_raw_data(filepath: str, nrows=None) -> pd.DataFrame:
    """
    Load only the columns relevant to the 4-layer data model.
    Skipping the other 120+ columns saves memory and load time.
    All messy columns (int_rate, term, dates) loaded as strings
    so pandas doesn't coerce or drop values during import.
    """
    COLUMNS = [
        "id", "loan_amnt", "funded_amnt", "term", "int_rate",
        "installment", "grade", "sub_grade", "emp_length",
        "home_ownership", "annual_inc", "verification_status",
        "issue_d", "loan_status", "purpose", "addr_state", "dti",
        "delinq_2yrs", "earliest_cr_line", "fico_range_low",
        "fico_range_high", "open_acc", "pub_rec", "revol_bal",
        "revol_util", "total_acc", "total_pymnt", "total_rec_prncp",
        "total_rec_int", "recoveries", "last_pymnt_amnt", "out_prncp",
        "collections_12_mths_ex_med",
    ]

    print(f"\n{DIVIDER}")
    print("  STEP 1: LOADING RAW DATA")
    print(DIVIDER)

    if not os.path.exists(filepath):
        raise FileNotFoundError(
            f"\nFile not found: {filepath}\n"
            "Download from: https://www.kaggle.com/datasets/"
            "wordsforthewise/lending-club\n"
            "Place accepted_2007_to_2018q4.csv in this folder."
        )

    df = pd.read_csv(
        filepath,
        usecols=COLUMNS,
        nrows=nrows,
        low_memory=False,
        dtype=str,              # load everything as string first
    )

    # convert numeric columns after load to preserve messy strings
    NUMERIC_COLS = [
        "loan_amnt", "funded_amnt", "installment", "annual_inc",
        "dti", "delinq_2yrs", "fico_range_low", "fico_range_high",
        "open_acc", "pub_rec", "revol_bal", "total_acc",
        "total_pymnt", "total_rec_prncp", "total_rec_int",
        "recoveries", "last_pymnt_amnt", "out_prncp",
        "collections_12_mths_ex_med",
    ]
    for col in NUMERIC_COLS:
        if col in df.columns:
            df[col] = pd.to_numeric(df[col], errors="coerce")

    print(f"  Rows loaded   : {len(df):,}")
    print(f"  Columns loaded: {df.shape[1]}")
    print(f"  Memory usage  : {df.memory_usage(deep=True).sum() / 1e6:.1f} MB")

    return df


# ══════════════════════════════════════════════════════════════════════
# STEP 2 — DATA QUALITY REPORT (BEFORE CLEANING)
# ══════════════════════════════════════════════════════════════════════

def generate_quality_report(df: pd.DataFrame, stage: str) -> dict:
    """
    Captures key quality metrics at a given stage.
    Run before and after cleaning to show what changed.
    """
    report = {
        "stage"        : stage,
        "rows"         : len(df),
        "columns"      : df.shape[1],
        "total_nulls"  : df.isnull().sum().sum(),
        "null_pct"     : round(df.isnull().mean().mean() * 100, 2),
        "duplicate_ids": df["id"].duplicated().sum() if "id" in df.columns else 0,
        "missing_by_col": (
            df.isnull()
            .sum()
            .sort_values(ascending=False)
            [lambda s: s > 0]
            .head(10)
            .to_dict()
        ),
    }
    return report


# ══════════════════════════════════════════════════════════════════════
# STEP 3 — CLEAN STRING → NUMERIC COLUMNS
# ══════════════════════════════════════════════════════════════════════

def clean_string_columns(df: pd.DataFrame) -> pd.DataFrame:
    """
    Fixes columns stored as strings in the raw CSV:
      int_rate   "15.27%"     →  15.27   (NUMERIC)
      revol_util "73.7%"      →  73.7    (NUMERIC)
      term       " 36 months" →  36      (INTEGER)
    """
    print("\n  Cleaning string → numeric columns...")

    # int_rate: "15.27%" → 15.27
    df["int_rate"] = (
        df["int_rate"]
        .str.replace("%", "", regex=False)
        .str.strip()
        .pipe(pd.to_numeric, errors="coerce")
    )

    # revol_util: "73.7%" → 73.7
    df["revol_util"] = (
        df["revol_util"]
        .str.replace("%", "", regex=False)
        .str.strip()
        .pipe(pd.to_numeric, errors="coerce")
    )

    # term: " 36 months" or " 60 months" → 36 or 60
    df["term_months"] = (
        df["term"]
        .str.extract(r"(\d+)")        # pull the number out
        .astype(float)
        .astype("Int64")              # Int64 supports NaN unlike int
    )
    df.drop(columns=["term"], inplace=True)

    print(f"    int_rate    : {df['int_rate'].notna().sum():,} valid values  "
          f"  range [{df['int_rate'].min():.2f}% – {df['int_rate'].max():.2f}%]")
    print(f"    revol_util  : {df['revol_util'].notna().sum():,} valid values  "
          f"  range [{df['revol_util'].min():.1f}% – {df['revol_util'].max():.1f}%]")
    print(f"    term_months : {df['term_months'].notna().sum():,} valid values  "
          f"  unique: {sorted(df['term_months'].dropna().unique().tolist())}")

    return df


# ══════════════════════════════════════════════════════════════════════
# STEP 4 — CLEAN EMPLOYMENT LENGTH
# ══════════════════════════════════════════════════════════════════════

def clean_employment_length(df: pd.DataFrame) -> pd.DataFrame:
    """
    emp_length is stored as text: "10+ years", "< 1 year", etc.
    Maps to numeric years. Unmapped values (NaN) filled with
    the median (5 years) as a conservative default.
    """
    print("\n  Cleaning employment length...")

    EMP_MAP = {
        "< 1 year":  0,
        "1 year":    1,
        "2 years":   2,
        "3 years":   3,
        "4 years":   4,
        "5 years":   5,
        "6 years":   6,
        "7 years":   7,
        "8 years":   8,
        "9 years":   9,
        "10+ years": 10,
    }

    before_nulls = df["emp_length"].isnull().sum()
    df["emp_length_yrs"] = df["emp_length"].map(EMP_MAP)
    after_nulls  = df["emp_length_yrs"].isnull().sum()

    # unmapped values get the median
    median_emp = df["emp_length_yrs"].median()
    df["emp_length_yrs"].fillna(median_emp, inplace=True)
    df.drop(columns=["emp_length"], inplace=True)

    print(f"    Mapped {len(EMP_MAP)} categories to numeric years")
    print(f"    Nulls before: {before_nulls:,}  →  after: {after_nulls:,} "
          f"  (filled with median = {median_emp:.0f} yrs)")

    return df


# ══════════════════════════════════════════════════════════════════════
# STEP 5 — PARSE DATE COLUMNS
# ══════════════════════════════════════════════════════════════════════

def parse_dates(df: pd.DataFrame) -> pd.DataFrame:
    """
    Converts "Mon-YYYY" string dates to proper datetime objects.
    'issue_d'          → when the loan was issued
    'earliest_cr_line' → when the borrower opened their first credit line
    Both are needed to compute credit_age_yrs later.
    """
    print("\n  Parsing date columns...")

    for col in ["issue_d", "earliest_cr_line"]:
        before_nulls = df[col].isnull().sum()
        df[col] = pd.to_datetime(df[col], format="%b-%Y", errors="coerce")
        after_nulls  = df[col].isnull().sum()
        new_nulls    = after_nulls - before_nulls
        print(f"    {col:20s}: {df[col].notna().sum():,} parsed  "
              f"  {new_nulls:,} unparseable → NaT")

    return df


# ══════════════════════════════════════════════════════════════════════
# STEP 6 — FILTER INVALID ROWS
# ══════════════════════════════════════════════════════════════════════

def filter_invalid_rows(df: pd.DataFrame) -> pd.DataFrame:
    """
    Removes rows missing values in columns that are required
    for every downstream analysis. These rows cannot be imputed
    — a loan without a grade, income, or FICO score is unusable.
    """
    print("\n  Filtering rows with missing required fields...")

    before = len(df)

    REQUIRED = ["annual_inc", "loan_status", "grade", "fico_range_low"]
    df.dropna(subset=REQUIRED, inplace=True)

    # also remove rows with clearly invalid values
    df = df[df["annual_inc"]    > 0]
    df = df[df["funded_amnt"]   > 0]
    df = df[df["fico_range_low"] > 0]

    removed = before - len(df)
    print(f"    Rows before : {before:,}")
    print(f"    Rows removed: {removed:,}  ({removed/before*100:.2f}%)")
    print(f"    Rows after  : {len(df):,}")

    return df


# ══════════════════════════════════════════════════════════════════════
# STEP 7 — FILL NULL VALUES
# ══════════════════════════════════════════════════════════════════════

def fill_nulls(df: pd.DataFrame) -> pd.DataFrame:
    """
    Fills remaining nulls with sensible defaults.
    Strategy per column:
      - Continuous financial ratios (dti, revol_util) → median
        (median is more robust to outliers than mean)
      - Count columns (delinq_2yrs, pub_rec, collections) → 0
        (missing = no events recorded, not truly unknown)
      - open_acc, total_acc → median
      - Payment columns → 0 (no payment received = 0)
    """
    print("\n  Filling null values...")

    # compute medians on non-null values
    dti_median      = df["dti"].median()
    revol_median    = df["revol_util"].median()
    open_acc_median = df["open_acc"].median()
    total_acc_med   = df["total_acc"].median()

    FILL_MAP = {
        # continuous → median
        "dti"                      : dti_median,
        "revol_util"               : revol_median,
        "open_acc"                 : open_acc_median,
        "total_acc"                : total_acc_med,
        "revol_bal"                : 0,
        # counts → 0 (absence of evidence = no events)
        "delinq_2yrs"              : 0,
        "pub_rec"                  : 0,
        "collections_12_mths_ex_med": 0,
        # payment columns → 0
        "total_pymnt"              : 0,
        "total_rec_prncp"          : 0,
        "total_rec_int"            : 0,
        "recoveries"               : 0,
        "last_pymnt_amnt"          : 0,
        "out_prncp"                : 0,
    }

    for col, fill_val in FILL_MAP.items():
        if col in df.columns:
            nulls = df[col].isnull().sum()
            if nulls > 0:
                df[col].fillna(fill_val, inplace=True)
                print(f"    {col:35s}: filled {nulls:,} nulls → {fill_val}")

    return df


# ══════════════════════════════════════════════════════════════════════
# STEP 8 — CAP OUTLIERS
# ══════════════════════════════════════════════════════════════════════

def cap_outliers(df: pd.DataFrame) -> pd.DataFrame:
    """
    Caps extreme values to prevent outliers from distorting
    aggregations and averages in SQL analytics.

    Approach: domain-knowledge caps (not percentile-based)
    because lending has well-understood valid ranges.

    annual_inc > $500K : one billionaire borrower would shift
                          the average income for 2M other rows
    dti > 100%         : mathematically impossible to have debt
                          payments exceed 100% of income long-term
    revol_util > 150%  : over-limit accounts exist but beyond
                          150% the value is likely a data error
    int_rate < 1%      : LendingClub minimum was ~5%; below 1%
                          is almost certainly a data entry error
    """
    print("\n  Capping outliers...")

    CAPS = {
        "annual_inc": (None, 500_000),
        "dti"        : (0,    100),
        "revol_util" : (0,    150),
        "int_rate"   : (1,     40),
        "funded_amnt": (500, None),
    }

    for col, (lower, upper) in CAPS.items():
        if col not in df.columns:
            continue
        before_min = df[col].min()
        before_max = df[col].max()
        if lower is not None:
            df[col] = df[col].clip(lower=lower)
        if upper is not None:
            df[col] = df[col].clip(upper=upper)
        after_min = df[col].min()
        after_max = df[col].max()
        print(f"    {col:15s}: [{before_min:>12.1f} – {before_max:>12.1f}]  "
              f"→  [{after_min:>12.1f} – {after_max:>12.1f}]")

    return df


# ══════════════════════════════════════════════════════════════════════
# STEP 9 — FEATURE ENGINEERING
# ══════════════════════════════════════════════════════════════════════

def engineer_features(df: pd.DataFrame) -> pd.DataFrame:
    """
    Creates derived columns used across all 4 SQL modules.
    These mirror the feature engineering done in the SQL
    cleaned_loans view so the CSV output is analysis-ready.

    fico_avg          average of fico_range_low and fico_range_high
    credit_age_yrs    years between earliest credit line and loan issue
    repayment_ratio   total_pymnt / funded_amnt
    net_loss          principal not recovered after default
    is_default        1 if Charged Off or Default, else 0
    is_closed         1 if loan has a final known outcome
    income_band       categorical income tier (1–5)
    fico_band         categorical FICO tier (1–5)
    dti_band          categorical DTI tier (1–5)
    """
    print("\n  Engineering derived features...")

    # ── FICO average ───────────────────────────────────────────────
    df["fico_avg"] = (df["fico_range_low"] + df["fico_range_high"]) / 2.0
    print(f"    fico_avg         : range [{df['fico_avg'].min():.0f} – "
          f"{df['fico_avg'].max():.0f}]")

    # ── Credit age ─────────────────────────────────────────────────
    # Days between earliest credit line opening and loan issue date,
    # converted to years. Negative or null values clipped to 0.
    df["credit_age_yrs"] = (
        (df["issue_d"] - df["earliest_cr_line"]).dt.days / 365.25
    ).clip(lower=0).round(1)
    print(f"    credit_age_yrs   : median = "
          f"{df['credit_age_yrs'].median():.1f} yrs  "
          f"  max = {df['credit_age_yrs'].max():.1f} yrs")

    # ── Repayment ratio ────────────────────────────────────────────
    # Fraction of funded amount that was paid back.
    # 1.0 = fully repaid, 0.5 = paid back half, >1.0 = paid interest too
    df["repayment_ratio"] = (
        df["total_pymnt"] / df["funded_amnt"].replace(0, np.nan)
    ).clip(0, 3).round(4)
    print(f"    repayment_ratio  : median = {df['repayment_ratio'].median():.2f}")

    # ── Net loss ───────────────────────────────────────────────────
    # Principal the lender will never recover.
    # = funded amount minus principal repaid minus post-charge-off recoveries
    # Clipped at 0: cannot have a negative loss (no negative loss on a loan)
    df["net_loss"] = (
        df["funded_amnt"] - df["total_rec_prncp"] - df["recoveries"]
    ).clip(lower=0).round(2)

    # ── Default and closed flags ───────────────────────────────────
    df["is_default"] = df["loan_status"].isin(
        ["Charged Off", "Default"]
    ).astype(int)

    df["is_closed"] = df["loan_status"].isin(
        ["Fully Paid", "Charged Off", "Default"]
    ).astype(int)

    default_rate = df["is_default"].mean() * 100
    closed_pct   = df["is_closed"].mean() * 100
    print(f"    is_default       : {df['is_default'].sum():,} defaults  "
          f"({default_rate:.1f}%)")
    print(f"    is_closed        : {df['is_closed'].sum():,} closed   "
          f"({closed_pct:.1f}%)")

    # ── Income band ────────────────────────────────────────────────
    # Numbered prefixes keep Tableau sort order correct.
    df["income_band"] = pd.cut(
        df["annual_inc"],
        bins=[0, 30_000, 60_000, 100_000, 200_000, float("inf")],
        labels=["1. <$30K", "2. $30–60K", "3. $60–100K",
                "4. $100–200K", "5. >$200K"],
    )

    # ── FICO band ──────────────────────────────────────────────────
    df["fico_band"] = pd.cut(
        df["fico_avg"],
        bins=[0, 580, 670, 740, 800, float("inf")],
        labels=["1. Poor <580", "2. Fair 580–670", "3. Good 670–740",
                "4. Very Good 740–800", "5. Exceptional >800"],
    )

    # ── DTI band ───────────────────────────────────────────────────
    df["dti_band"] = pd.cut(
        df["dti"],
        bins=[0, 15, 25, 35, 50, float("inf")],
        labels=["1. <15%", "2. 15–25%", "3. 25–35%",
                "4. 35–50%", "5. >50%"],
    )

    print(f"\n    Income band distribution:")
    print(df["income_band"].value_counts().sort_index()
            .to_string(dtype=False))

    print(f"\n    FICO band distribution:")
    print(df["fico_band"].value_counts().sort_index()
            .to_string(dtype=False))

    return df


# ══════════════════════════════════════════════════════════════════════
# STEP 10 — FINAL COLUMN SELECTION & ORDERING
# ══════════════════════════════════════════════════════════════════════

def select_final_columns(df: pd.DataFrame) -> pd.DataFrame:
    """
    Selects and orders the final output columns.
    Grouped by the 4 data model layers so the CSV structure
    mirrors dim_customer / fact_loans / fact_repayments /
    dim_credit_history in the SQL files.
    """
    FINAL_COLS = [
        # ── identifiers ──
        "id",

        # ── dim_customer ──
        "annual_inc", "emp_length_yrs", "home_ownership",
        "addr_state", "verification_status", "income_band",

        # ── fact_loans ──
        "loan_amnt", "funded_amnt", "term_months", "int_rate",
        "installment", "grade", "sub_grade", "purpose",
        "issue_d", "loan_status", "is_default", "is_closed",

        # ── fact_repayments ──
        "total_pymnt", "total_rec_prncp", "total_rec_int",
        "recoveries", "last_pymnt_amnt", "out_prncp",
        "repayment_ratio", "net_loss",

        # ── dim_credit_history ──
        "fico_avg", "fico_range_low", "fico_range_high", "fico_band",
        "dti", "dti_band", "delinq_2yrs", "open_acc", "pub_rec",
        "revol_bal", "revol_util", "total_acc",
        "credit_age_yrs", "collections_12_mths_ex_med",

        # ── date columns ──
        "earliest_cr_line",
    ]

    # keep only columns that exist (handles edge cases)
    FINAL_COLS = [c for c in FINAL_COLS if c in df.columns]
    return df[FINAL_COLS]


# ══════════════════════════════════════════════════════════════════════
# STEP 11 — WRITE QUALITY REPORT
# ══════════════════════════════════════════════════════════════════════

def write_quality_report(before: dict, after: dict,
                          df_clean: pd.DataFrame, path: str) -> None:
    """
    Writes a before/after data quality summary to a text file.
    Useful for documenting what cleaning did and for interviews
    ("what issues did you find in the data?").
    """
    lines = [
        "=" * 65,
        "  LENDING ANALYTICS — DATA QUALITY REPORT",
        f"  Generated: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}",
        "=" * 65,
        "",
        "── BEFORE CLEANING ──────────────────────────────────────",
        f"  Rows             : {before['rows']:,}",
        f"  Columns          : {before['columns']}",
        f"  Total nulls      : {before['total_nulls']:,}",
        f"  Avg null rate    : {before['null_pct']:.2f}%",
        f"  Duplicate IDs    : {before['duplicate_ids']:,}",
        "",
        "  Top 10 columns by null count:",
    ]
    for col, cnt in before["missing_by_col"].items():
        pct = cnt / before["rows"] * 100
        lines.append(f"    {col:35s}: {cnt:>8,}  ({pct:.1f}%)")

    lines += [
        "",
        "── AFTER CLEANING ───────────────────────────────────────",
        f"  Rows             : {after['rows']:,}",
        f"  Columns          : {after['columns']}",
        f"  Total nulls      : {after['total_nulls']:,}",
        f"  Avg null rate    : {after['null_pct']:.2f}%",
        f"  Rows removed     : {before['rows'] - after['rows']:,}  "
        f"({(before['rows'] - after['rows']) / before['rows'] * 100:.2f}%)",
        "",
        "── KEY METRICS ──────────────────────────────────────────",
        f"  Default rate     : "
        f"{df_clean['is_default'].mean() * 100:.2f}%",
        f"  Closed loans     : "
        f"{df_clean['is_closed'].mean() * 100:.2f}%",
        f"  Avg funded amt   : "
        f"${df_clean['funded_amnt'].mean():,.0f}",
        f"  Avg int_rate     : "
        f"{df_clean['int_rate'].mean():.2f}%",
        f"  Avg FICO         : "
        f"{df_clean['fico_avg'].mean():.0f}",
        f"  Avg DTI          : "
        f"{df_clean['dti'].mean():.1f}%",
        f"  Avg credit age   : "
        f"{df_clean['credit_age_yrs'].mean():.1f} yrs",
        "",
        "── COLUMN SUMMARY ───────────────────────────────────────",
    ]

    for col in df_clean.columns:
        null_count = df_clean[col].isnull().sum()
        null_str   = f"{null_count:,} nulls" if null_count > 0 else "no nulls"
        dtype_str  = str(df_clean[col].dtype)
        lines.append(f"  {col:35s}: {dtype_str:15s}  {null_str}")

    lines += ["", "=" * 65]

    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))

    print(f"\n  Report saved  → {path}")


# ══════════════════════════════════════════════════════════════════════
# MAIN PIPELINE
# ══════════════════════════════════════════════════════════════════════

def main():
    print(DIVIDER)
    print("  LENDING ANALYTICS — DATA CLEANING PIPELINE")
    print(DIVIDER)
    start = datetime.now()

    # Step 1: Load
    df = load_raw_data(INPUT_FILE, nrows=SAMPLE_ROWS)

    # Quality snapshot before cleaning
    print(f"\n{DIVIDER}")
    print("  STEP 2: PRE-CLEANING QUALITY SNAPSHOT")
    print(DIVIDER)
    report_before = generate_quality_report(df, "before")
    print(f"  Total nulls   : {report_before['total_nulls']:,}")
    print(f"  Avg null rate : {report_before['null_pct']:.2f}%")
    print(f"  Duplicate IDs : {report_before['duplicate_ids']:,}")

    print(f"\n  Top 10 columns with missing values:")
    for col, cnt in report_before["missing_by_col"].items():
        pct = cnt / len(df) * 100
        bar = "█" * int(pct / 2)
        print(f"    {col:35s}: {cnt:>8,}  ({pct:5.1f}%)  {bar}")

    # Step 3–9: Clean
    print(f"\n{DIVIDER}")
    print("  STEPS 3–9: CLEANING & FEATURE ENGINEERING")
    print(DIVIDER)

    df = clean_string_columns(df)
    df = clean_employment_length(df)
    df = parse_dates(df)
    df = filter_invalid_rows(df)
    df = fill_nulls(df)
    df = cap_outliers(df)
    df = engineer_features(df)

    # Step 10: Final column selection
    print("\n  Selecting final columns...")
    df = select_final_columns(df)
    print(f"    Final shape   : {df.shape[0]:,} rows × {df.shape[1]} columns")

    # Quality snapshot after cleaning
    report_after = generate_quality_report(df, "after")

    # Step 11: Write quality report
    print(f"\n{DIVIDER}")
    print("  STEP 10: WRITING QUALITY REPORT")
    print(DIVIDER)
    write_quality_report(report_before, report_after, df, REPORT_FILE)

    # Step 12: Export clean CSV
    print(f"\n{DIVIDER}")
    print("  STEP 11: EXPORTING CLEAN CSV")
    print(DIVIDER)
    df.to_csv(OUTPUT_FILE, index=False)
    size_mb = os.path.getsize(OUTPUT_FILE) / 1e6
    print(f"  Saved         → {OUTPUT_FILE}")
    print(f"  File size     : {size_mb:.1f} MB")
    print(f"  Rows          : {len(df):,}")
    print(f"  Columns       : {df.shape[1]}")

    elapsed = (datetime.now() - start).seconds
    print(f"\n  Total time    : {elapsed}s")
    print(f"\n{DIVIDER}")
    print("  NEXT STEPS:")
    print(f"  1. Load {OUTPUT_FILE} into PostgreSQL:")
    print(f"     \\COPY loans_raw FROM '{OUTPUT_FILE}' CSV HEADER NULL '';")
    print("  2. Run: 01_data_model.sql")
    print("  3. Run: 02_risk_analytics.sql")
    print("  4. Run: 03_credit_approval_engine.sql")
    print("  5. Run: 04_profitability_simulation.sql")
    print("  6. Connect Tableau to PostgreSQL → tableau_* views")
    print(DIVIDER)

    return df


if __name__ == "__main__":
    df_clean = main()
