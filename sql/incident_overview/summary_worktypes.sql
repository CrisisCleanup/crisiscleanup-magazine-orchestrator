-- Generates data for multiple visualizations:
--   5_worktype_donut.csv
--   10_commercial_value_of_services.csv
--   11_cases_by_worktype.csv

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
worksites_in_period AS (
  -- Find all worksites that appear in the analysis period
  SELECT DISTINCT
    worksite_id
  FROM r.cases_new_claimed_closed_omni_mag
  WHERE incident_id = ANY(string_to_array('175', ',')::int[])
    AND is_within_analysis = true
    AND invalidated_at IS NULL
),
end_of_period_snapshot AS (
  -- Get the final snapshot for each worksite's work types
  -- Use DISTINCT ON to get latest snapshot by date
  SELECT DISTINCT ON (omni.worksite_id, omni.work_type_key)
    omni.worksite_id,
    omni.work_type_key,
    omni.running_count_claimed_worksite,
    omni.work_type_value,
    omni.percent_closed_hash
  FROM r.cases_new_claimed_closed_omni_mag omni
  INNER JOIN worksites_in_period wp ON omni.worksite_id = wp.worksite_id
  WHERE omni.incident_id = ANY(string_to_array('175', ',')::int[])
    AND omni.is_within_analysis = true
    AND omni.work_type_key NOT IN ('mold_remediation', 'rebuild', 'heating')
    AND omni.invalidated_at IS NULL  -- Exclude invalidated work types
  ORDER BY omni.worksite_id, omni.work_type_key, omni.the_date DESC, omni.created_at DESC
),
worksite_aggregates AS (
  -- Aggregate work types to worksite level
  SELECT
    worksite_id,
    work_type_key,
    -- Track if this work type is claimed/closed at worksite level
    MAX(CASE WHEN running_count_claimed_worksite > 0 THEN 1 ELSE 0 END) AS is_claimed,
    work_type_value,
    percent_closed_hash,
    -- Calculate closed commercial value using percent_closed_hash
    SUM(work_type_value * percent_closed_hash) AS closed_commercial_value
  FROM end_of_period_snapshot
  GROUP BY worksite_id, work_type_key, work_type_value, percent_closed_hash
),
worktype_aggregates AS (
  -- Aggregate worksites by work type
  SELECT
    work_type_key,
    COUNT(DISTINCT worksite_id) AS total_cases,
    SUM(is_claimed) AS claimed_cases,
    -- Closed cases = count worksites where this work type is fully closed
    SUM(CASE WHEN percent_closed_hash = 1.0 THEN 1 ELSE 0 END) AS closed_cases,
    SUM(work_type_value) AS total_commercial_value,
    SUM(closed_commercial_value) AS closed_commercial_value
  FROM worksite_aggregates
  GROUP BY work_type_key
)
-- Output for 5_worktype_donut, 10_commercial_value_of_services, and 11_cases_by_worktype
SELECT
  work_type_key,
  closed_cases AS "Closed",
  -- Open Claimed = claimed but not yet closed
  (claimed_cases - closed_cases) AS "Open Claimed",
  -- Open Unclaimed = created but never claimed
  (total_cases - claimed_cases) AS "Open Unclaimed",
  closed_commercial_value,
  -- Approximate open claimed commercial value
  CASE
    WHEN total_cases > 0 THEN
      (total_commercial_value * (claimed_cases - closed_cases) / NULLIF(total_cases, 0))
    ELSE 0
  END AS open_claimed_commercial_value,
  -- Approximate open unclaimed commercial value
  CASE
    WHEN total_cases > 0 THEN
      (total_commercial_value * (total_cases - claimed_cases) / NULLIF(total_cases, 0))
    ELSE 0
  END AS open_unclaimed_commercial_value
FROM worktype_aggregates
WHERE work_type_key IS NOT NULL
ORDER BY closed_commercial_value DESC;
