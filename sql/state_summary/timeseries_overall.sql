-- 6_cases_by_status.csv (state-level)
-- NOTE: This query outputs daily NEW case counts (not cumulative)
-- Post-processing WILL apply cumulative calculations via .cumsum()

WITH target_incident AS (
  -- Selects the target incidents
  -- Support for multiple incident IDs: e.g., '175' or '175,172,180'
  SELECT
    id,
    name,
    start_at,
    timezone
  FROM incident_incidents
  WHERE id = ANY(string_to_array('175', ',')::int[])
),
worksite_first_appearance AS (
  -- Find the first date each worksite appears in the analysis period for this state
  -- This serves as the "creation date" for grouping purposes
  SELECT DISTINCT ON (worksite_id)
    worksite_id,
    the_date AS creation_date
  FROM r.cases_new_claimed_closed_omni_mag
  WHERE incident_id = ANY(string_to_array('175', ',')::int[])
    AND is_within_analysis = true
    AND RIGHT(COALESCE(home_local_division_name, home_city_name), 2) = 'STATE_PLACEHOLDER'
    AND invalidated_at IS NULL
  ORDER BY worksite_id, the_date ASC
),
analysis_dates AS (
  -- Get all unique dates from worksite first appearances
  SELECT DISTINCT creation_date
  FROM worksite_first_appearance
  ORDER BY creation_date
),
latest_snapshot_with_creation AS (
  -- Get the LATEST status for each work type in this state, with its worksite's first appearance date
  -- NOTE: is_daily_last is NULL for most rows, so we use DISTINCT ON with the_date DESC instead
  SELECT DISTINCT ON (omni_latest.worksite_id, omni_latest.work_type_key)
    wfa.creation_date,
    omni_latest.worksite_id,
    omni_latest.work_type_key,
    omni_latest.work_type_value,
    omni_latest.percent_closed_hash,
    omni_latest.wwwtsp_claimed_by
  FROM r.cases_new_claimed_closed_omni_mag omni_latest
  INNER JOIN worksite_first_appearance wfa ON omni_latest.worksite_id = wfa.worksite_id
  WHERE omni_latest.incident_id = ANY(string_to_array('175', ',')::int[])
    AND omni_latest.is_within_analysis = true
    AND RIGHT(COALESCE(omni_latest.home_local_division_name, omni_latest.home_city_name), 2) = 'STATE_PLACEHOLDER'
    AND omni_latest.work_type_key NOT IN ('mold_remediation', 'rebuild', 'heating')
    AND omni_latest.invalidated_at IS NULL
  ORDER BY omni_latest.worksite_id, omni_latest.work_type_key, omni_latest.the_date DESC
),
work_type_values AS (
  -- Stage 1: Use creation date for grouping, latest status for values
  SELECT
    worksite_id,
    creation_date,
    work_type_value,
    percent_closed_hash,
    wwwtsp_claimed_by,
    -- Calculate closed and open values using LATEST status
    work_type_value * percent_closed_hash AS closed_value,
    work_type_value * (1 - percent_closed_hash) AS open_value,
    -- Flags for status categorization using LATEST status
    CASE WHEN wwwtsp_claimed_by IS NOT NULL THEN 1 ELSE 0 END AS is_claimed
  FROM latest_snapshot_with_creation
),
worksite_ratios AS (
  -- Stage 2: Aggregate work types to worksite level for each date
  SELECT
    worksite_id,
    creation_date,
    SUM(closed_value) AS total_closed_value,
    SUM(open_value) FILTER (WHERE is_claimed = 1) AS open_claimed_value,
    SUM(open_value) FILTER (WHERE is_claimed = 0) AS open_unclaimed_value,
    SUM(work_type_value) AS total_worksite_value
  FROM work_type_values
  GROUP BY worksite_id, creation_date
),
daily_summary AS (
  -- Stage 3: Sum worksite ratios to get daily NEW case counts
  -- These are daily increments that will be cumsum'd in post-processing
  SELECT
    creation_date,
    SUM(total_closed_value / NULLIF(total_worksite_value, 0)) AS closed_cases,
    SUM(open_claimed_value / NULLIF(total_worksite_value, 0)) AS open_claimed_cases,
    SUM(open_unclaimed_value / NULLIF(total_worksite_value, 0)) AS open_unclaimed_cases,
    SUM(total_closed_value) AS closed_commercial_value,
    SUM(open_claimed_value) AS open_claimed_value,
    SUM(open_unclaimed_value) AS open_unclaimed_value
  FROM worksite_ratios
  GROUP BY creation_date
),
calculated_values AS (
  -- Rename for compatibility with existing output structure
  SELECT
    creation_date,
    closed_cases,
    open_claimed_cases,
    open_unclaimed_cases,
    closed_commercial_value,
    open_claimed_value,
    open_unclaimed_value
  FROM daily_summary
)
-- Join with date range to ensure all dates are present
SELECT
  ad.creation_date,
  COALESCE(cv.closed_cases, 0) AS "Closed",
  COALESCE(cv.open_claimed_cases, 0) AS "Open Claimed",
  COALESCE(cv.open_unclaimed_cases, 0) AS "Open Unclaimed",
  COALESCE(cv.closed_commercial_value, 0) AS closed_commercial_value,
  COALESCE(cv.open_claimed_value, 0) AS open_claimed_value,
  COALESCE(cv.open_unclaimed_value, 0) AS open_unclaimed_value
FROM analysis_dates ad
LEFT JOIN calculated_values cv ON ad.creation_date = cv.creation_date
ORDER BY ad.creation_date;
