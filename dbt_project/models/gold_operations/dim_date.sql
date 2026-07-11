-- ============================================================
-- model:        dim_date
-- layer:        gold_operations (conformed dimension)
-- description:  Generated date dimension covering the full
--               SwiftRoute simulation period plus a forward
--               buffer. No source table, pure SQL generation.
--
-- key facts:
--   - date_key format: YYYYMMDD integer (e.g. 20250101).
--     Integer keys are faster for fact table joins than
--     date type keys.
--   - Covers 2024-01-01 to 2026-12-31. Pipeline-safe: range
--     is generous enough to cover all simulation data plus
--     future incremental runs without hardcoding exact dates.
--   - is_weekend: Saturday (6) and Sunday (0) in PostgreSQL
--     DOW convention (0=Sunday, 6=Saturday).
--   - is_holiday: placeholder FALSE for all dates. Can be
--     updated with a static seed file later if needed.
--   - quarter: 1 to 4, derived from month.
--   - fiscal_month, fiscal_quarter: same as calendar for now.
--     Adjust offset if SwiftRoute uses a non-calendar fiscal
--     year in future.
--
-- materialized: table (static reference, full rebuild is fine,
--               date spines do not change once generated)
--
-- depends_on:   none
-- ============================================================

{{
    config(
        materialized='table',
        schema='gold_operations'
    )
}}

-- ============================================================
-- SECTION 1: GENERATE DATE SPINE
-- Uses PostgreSQL GENERATE_SERIES to produce one row per day
-- across the full date range. Pipeline-safe: adjust start
-- and end dates here only if the simulation period changes.
-- ============================================================
WITH date_spine AS (

    SELECT
        GENERATE_SERIES(
            '2024-01-01'::DATE,
            '2026-12-31'::DATE,
            '1 day'::INTERVAL
        )::DATE                                                     AS full_date

),

-- ============================================================
-- SECTION 2: ENRICH
-- Derive all date attributes from full_date. Every column
-- is computed, not hardcoded, so the spine is fully
-- pipeline-safe and reusable for any date range.
-- ============================================================
enriched AS (

    SELECT
        full_date,

        -- integer key: YYYYMMDD format for fast fact joins
        TO_CHAR(full_date, 'YYYYMMDD')::INT                         AS date_key,

        -- calendar attributes
        EXTRACT(DAY FROM full_date)::INT                            AS day,
        EXTRACT(DOW FROM full_date)::INT                            AS day_of_week_num,
        TO_CHAR(full_date, 'Day')                                   AS day_of_week_name,
        EXTRACT(WEEK FROM full_date)::INT                           AS week,
        EXTRACT(MONTH FROM full_date)::INT                          AS month,
        TO_CHAR(full_date, 'Month')                                 AS month_name,
        TO_CHAR(full_date, 'Mon')                                   AS month_short,
        EXTRACT(QUARTER FROM full_date)::INT                        AS quarter,
        'Q' || EXTRACT(QUARTER FROM full_date)::INT                 AS quarter_label,
        EXTRACT(YEAR FROM full_date)::INT                           AS year,

        -- year-month label for reporting (e.g. 2025-01)
        TO_CHAR(full_date, 'YYYY-MM')                               AS year_month,

        -- year-quarter label for reporting (e.g. 2025-Q1)
        TO_CHAR(full_date, 'YYYY') || '-Q' ||
        EXTRACT(QUARTER FROM full_date)::INT                        AS year_quarter,

        -- weekend flag
        -- PostgreSQL DOW: 0 = Sunday, 6 = Saturday
        CASE
            WHEN EXTRACT(DOW FROM full_date) IN (0, 6) THEN TRUE
            ELSE FALSE
        END                                                         AS is_weekend,

        -- weekday flag (inverse of weekend)
        CASE
            WHEN EXTRACT(DOW FROM full_date) IN (0, 6) THEN FALSE
            ELSE TRUE
        END                                                         AS is_weekday,

        -- holiday placeholder (extend with seed file if needed)
        FALSE                                                       AS is_holiday,

        -- fiscal attributes (calendar-aligned for now)
        -- adjust month offset here if fiscal year differs
        EXTRACT(MONTH FROM full_date)::INT                          AS fiscal_month,
        EXTRACT(QUARTER FROM full_date)::INT                        AS fiscal_quarter,
        EXTRACT(YEAR FROM full_date)::INT                           AS fiscal_year,

        -- first and last day of month flags (useful for
        -- monthly aggregation boundaries in fact tables)
        CASE
            WHEN full_date = DATE_TRUNC('month', full_date)::DATE
            THEN TRUE
            ELSE FALSE
        END                                                         AS is_first_day_of_month,

        CASE
            WHEN full_date = (
                DATE_TRUNC('month', full_date) +
                INTERVAL '1 month' - INTERVAL '1 day'
            )::DATE
            THEN TRUE
            ELSE FALSE
        END                                                         AS is_last_day_of_month

    FROM date_spine

)

-- ============================================================
-- SECTION 3: FINAL SELECT
-- date_key as first column for clarity. full_date second
-- for human readability when browsing the table.
-- ============================================================
SELECT
    date_key,
    full_date,
    day,
    day_of_week_num,
    day_of_week_name,
    day_of_week_name                                                AS day_name,
    is_weekend,
    is_weekday,
    week,
    month,
    month_name,
    month_short,
    year_month,
    quarter,
    quarter_label,
    year_quarter,
    year,
    fiscal_month,
    fiscal_quarter,
    fiscal_year,
    is_first_day_of_month,
    is_last_day_of_month,
    is_holiday

FROM enriched

ORDER BY full_date