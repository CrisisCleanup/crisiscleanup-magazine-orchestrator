-- 7_worktype_closures.csv
-- Outputs daily closed-case ratios per work type for a single state. The
-- post-processor pivots into one column per work type and applies cumsum.

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
analysis_dates AS (
  -- Get all unique snapshot dates within analysis period
  -- NOTE: is_daily_last is NULL for most rows, so we don't filter by it
  SELECT DISTINCT the_date
  FROM r.cases_new_claimed_closed_omni_mag
  WHERE incident_id = ANY(string_to_array('175', ',')::int[])
    AND is_within_analysis = true
    AND invalidated_at IS NULL  -- Exclude invalidated work types
  ORDER BY the_date
),
work_types AS (
  -- Get all work types that appear in the omni data
  SELECT DISTINCT work_type_key
  FROM r.cases_new_claimed_closed_omni_mag
  WHERE incident_id = ANY(string_to_array('175', ',')::int[])
    AND is_within_analysis = true
    AND work_type_key NOT IN ('mold_remediation', 'rebuild', 'heating')
    AND invalidated_at IS NULL  -- Exclude invalidated work types
),
date_worktype_combos AS (
  -- Create all combinations of dates and work types
  SELECT
    ad.the_date AS creation_date,
    wt.work_type_key AS work_type_key
  FROM analysis_dates ad
  CROSS JOIN work_types wt
),
work_type_values AS (
  -- Stage 1: Get latest snapshot for each work type on each date in this state
  -- NOTE: is_daily_last is NULL for most rows, so we use DISTINCT ON instead
  SELECT DISTINCT ON (omni.worksite_id, omni.work_type_key, omni.the_date)
    omni.worksite_id,
    omni.the_date AS creation_date,
    omni.work_type_key,
    omni.work_type_value,
    omni.percent_closed_hash,
    -- Calculate closed value for this specific work type
    omni.work_type_value * omni.percent_closed_hash AS closed_value
  FROM r.cases_new_claimed_closed_omni_mag omni
  WHERE omni.incident_id = ANY(string_to_array('175', ',')::int[])
    AND omni.is_within_analysis = true
    AND RIGHT(COALESCE(omni.home_local_division_name, omni.home_city_name), 2) = 'STATE_PLACEHOLDER'  -- State filter
    AND omni.work_type_key NOT IN ('mold_remediation', 'rebuild', 'heating')
    AND omni.invalidated_at IS NULL
  ORDER BY omni.worksite_id, omni.work_type_key, omni.the_date, omni.created_at DESC
),
worksite_totals AS (
  -- Calculate total value for each worksite across ALL work types
  SELECT
    worksite_id,
    creation_date,
    SUM(work_type_value) AS total_worksite_value
  FROM work_type_values
  GROUP BY worksite_id, creation_date
),
worksite_aggregates AS (
  -- Stage 2: Join work type values with worksite totals
  SELECT
    wtv.worksite_id,
    wtv.creation_date,
    wtv.work_type_key,
    wtv.closed_value AS this_worktype_closed_value,
    wt.total_worksite_value
  FROM work_type_values wtv
  INNER JOIN worksite_totals wt
    ON wtv.worksite_id = wt.worksite_id
    AND wtv.creation_date = wt.creation_date
),
daily_closures AS (
  -- Stage 3: Sum worksite ratios by work type and date (ratio-based counting)
  SELECT
    creation_date,
    work_type_key,
    -- Ratio-based counting: for each worksite, count the fraction this work type represents
    SUM(this_worktype_closed_value / NULLIF(total_worksite_value, 0)) AS closed_cases
  FROM worksite_aggregates
  GROUP BY creation_date, work_type_key
)
-- Output normalized format for 7_worktype_closures (creation_date, work_type_key, closed_cases)
SELECT
  dwt.creation_date,
  dwt.work_type_key,
  COALESCE(dc.closed_cases, 0) AS closed_cases
FROM date_worktype_combos dwt
LEFT JOIN daily_closures dc
  ON dc.creation_date = dwt.creation_date
  AND dc.work_type_key = dwt.work_type_key
WHERE dwt.work_type_key IS NOT NULL
ORDER BY dwt.creation_date, dwt.work_type_key;
