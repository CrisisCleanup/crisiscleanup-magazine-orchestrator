-- 13_commercial_value_svi.csv
-- NOTE: Post-processing ensures all 10 SVI buckets (0.0-0.1 through 0.9-1.0) are present

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
worksites_with_svi AS (
  -- Get SVI from worksite table for all worksites in analysis period in this state
  SELECT DISTINCT
    omni.worksite_id,
    ww.svi
  FROM r.cases_new_claimed_closed_omni_mag omni
  INNER JOIN worksite_worksites ww ON omni.worksite_id = ww.id
  WHERE omni.incident_id = ANY(string_to_array('175', ',')::int[])
    AND omni.is_within_analysis = true
    AND RIGHT(COALESCE(omni.home_local_division_name, omni.home_city_name), 2) = 'STATE_PLACEHOLDER'  -- State filter
    AND ww.svi IS NOT NULL
    AND omni.invalidated_at IS NULL
),
end_of_period_snapshot AS (
  -- Get the final snapshot for each worksite's work types using DISTINCT ON
  SELECT DISTINCT ON (omni.worksite_id, omni.work_type_key)
    omni.worksite_id,
    ws.svi,
    omni.work_type_key,
    omni.running_count_claimed_worksite,
    omni.work_type_value,
    omni.percent_closed_hash
  FROM r.cases_new_claimed_closed_omni_mag omni
  INNER JOIN worksites_with_svi ws ON omni.worksite_id = ws.worksite_id
  WHERE omni.incident_id = ANY(string_to_array('175', ',')::int[])
    AND omni.is_within_analysis = true
    AND RIGHT(COALESCE(omni.home_local_division_name, omni.home_city_name), 2) = 'STATE_PLACEHOLDER'
    AND omni.work_type_key NOT IN ('mold_remediation', 'rebuild', 'heating')
    AND omni.invalidated_at IS NULL  -- Exclude invalidated work types
  ORDER BY omni.worksite_id, omni.work_type_key, omni.the_date DESC, omni.created_at DESC
),
worksite_aggregates AS (
  -- Aggregate work types to worksite level
  SELECT
    worksite_id,
    svi,
    SUM(work_type_value) AS total_value,
    SUM(work_type_value * percent_closed_hash) AS closed_value,
    MAX(CASE WHEN running_count_claimed_worksite > 0 THEN 1 ELSE 0 END) AS is_claimed
  FROM end_of_period_snapshot
  GROUP BY worksite_id, svi
),
svi_bucket_aggregates AS (
  -- Aggregate worksites by SVI bucket (calculate bin first, then aggregate)
  SELECT
    CONCAT(
      LPAD(CAST(FLOOR(svi * 10) / 10.0 AS TEXT), 3, '0'),
      ' - ',
      LPAD(CAST((FLOOR(svi * 10) + 1) / 10.0 AS TEXT), 3, '0')
    ) AS svi_bin,
    COUNT(worksite_id) AS total_cases,
    SUM(is_claimed) AS claimed_cases,
    -- Closed cases = sum of ratios
    SUM(closed_value / NULLIF(total_value, 0)) AS closed_cases,
    SUM(total_value) AS total_commercial_value,
    SUM(closed_value) AS closed_commercial_value
  FROM worksite_aggregates
  GROUP BY svi_bin
)
SELECT
  svi_bin,
  closed_commercial_value AS closed_value,
  -- Approximate open claimed commercial value
  CASE
    WHEN total_cases > 0 THEN
      (total_commercial_value * (claimed_cases - closed_cases) / NULLIF(total_cases, 0))
    ELSE 0
  END AS open_claimed_value,
  -- Approximate open unclaimed commercial value
  CASE
    WHEN total_cases > 0 THEN
      (total_commercial_value * (total_cases - claimed_cases) / NULLIF(total_cases, 0))
    ELSE 0
  END AS open_unclaimed_value
FROM svi_bucket_aggregates
ORDER BY svi_bin DESC;
