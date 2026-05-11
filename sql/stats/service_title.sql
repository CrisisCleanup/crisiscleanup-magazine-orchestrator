-- Supporting Service Title Statistics
-- Generates dynamic title text about commercial value of top work types
-- Output: Two-column format with "content" and "value"

WITH target_incident AS (
  -- Selects the target incidents and their configured start dates in their local timezones
  -- Support for multiple incident IDs (comma-separated): e.g., '175' or '175,172,180'
  SELECT
    id,
    start_at,
    timezone,
    DATE(start_at AT TIME ZONE 'UTC' AT TIME ZONE timezone) AS configured_start_date_tz
  FROM incident_incidents
  WHERE id = ANY(string_to_array('175', ',')::int[]) -- Specify the target incident ID(s) here
),
first_case_per_incident AS (
  -- Calculate first case creation date for each incident individually
  SELECT
    ti.id,
    ti.configured_start_date_tz,
    ti.timezone,
    MIN(DATE(aw.created_at AT TIME ZONE 'UTC' AT TIME ZONE ti.timezone)) AS first_actual_case_date
  FROM target_incident ti
  LEFT JOIN worksite_worksites aw ON aw.incident_id = ti.id AND aw.invalidated_at IS NULL
  GROUP BY ti.id, ti.configured_start_date_tz, ti.timezone
),
incident_analysis_periods AS (
  -- Calculate analysis start and end for each incident individually
  SELECT
    id,
    GREATEST(configured_start_date_tz, COALESCE(first_actual_case_date, configured_start_date_tz)) AS analysis_start,
    GREATEST(configured_start_date_tz, COALESCE(first_actual_case_date, configured_start_date_tz)) + INTERVAL '59 days' AS analysis_end
  FROM first_case_per_incident
),
report_period AS (
  -- Multi-incident logic: earliest analysis start to latest analysis end
  SELECT
    MIN(analysis_start)::DATE AS report_start_date,
    MAX(analysis_end)::DATE AS report_end_date
  FROM incident_analysis_periods
),
work_type_commercial_values AS (
  -- Calculate closed commercial values by work type using standardized logic
  SELECT
    wwwtsp.work_type_key,
    SUM(wwt.commercial_value * wws.completed_by_anybody) AS closed_commercial_value
  FROM worksite_worksites aw
  INNER JOIN target_incident ti ON aw.incident_id = ti.id
  CROSS JOIN report_period rp
  LEFT JOIN worksite_worksites_work_types_statuses_phases wwwtsp ON aw.id = wwwtsp.worksite_id
  LEFT JOIN worksite_work_statuses wws ON wwwtsp.status_key = wws.status
  LEFT JOIN worksite_work_types wwt ON wwwtsp.work_type_key = wwt.key
  WHERE wwwtsp.invalidated_at IS NULL
    AND aw.invalidated_at IS NULL
    AND wwwtsp.work_type_key IS NOT NULL
    AND wwwtsp.work_type_key NOT IN ('mold_remediation', 'rebuild', 'heating', 'shopping', 'report')
    AND DATE(aw.created_at AT TIME ZONE 'UTC' AT TIME ZONE ti.timezone)
        BETWEEN rp.report_start_date AND rp.report_end_date
  GROUP BY wwwtsp.work_type_key
  HAVING SUM(wwt.commercial_value * wws.completed_by_anybody) > 0
),
formatted_work_types AS (
  -- Format work type names and commercial values with proper scaling
  SELECT
    work_type_key,
    closed_commercial_value,
    CASE
      WHEN work_type_key = 'trees' THEN 'tree services'
      WHEN work_type_key = 'mucb_bucb' THEN 'muck outs'
      WHEN work_type_key = 'debris' THEN 'debris services'
      WHEN work_type_key = 'tarp' THEN 'tarping services'
      WHEN work_type_key = 'ash' THEN 'ash cleanup'
      WHEN work_type_key = 'animal_services' THEN 'animal services'
      WHEN work_type_key = 'catchment_gutters' THEN 'gutter services'
      WHEN work_type_key = 'fence' THEN 'fencing services'
      WHEN work_type_key = 'sandbagging' THEN 'sandbagging'
      ELSE REPLACE(work_type_key, '_', ' ') || ' services'
    END AS formatted_work_type,
    CASE
      -- Format as $X.Xk for thousands (912 -> $0.9k, 121401 -> $121.4k)
      WHEN closed_commercial_value < 1000 THEN
        '$' || ROUND(closed_commercial_value / 1000.0, 1)::text || 'k'
      WHEN closed_commercial_value < 1000000 THEN
        '$' || ROUND(closed_commercial_value / 1000.0, 1)::text || 'k'
      -- Format as $X.XM for millions (54879003 -> $54.9M)
      ELSE
        '$' || ROUND(closed_commercial_value / 1000000.0, 1)::text || 'M'
    END AS formatted_value,
    ROW_NUMBER() OVER (ORDER BY closed_commercial_value DESC) AS rank_order
  FROM work_type_commercial_values
),
all_significant_work_types AS (
  -- Get all work types with meaningful commercial value (no arbitrary limit)
  SELECT
    STRING_AGG(
      formatted_value || ' in ' || formatted_work_type,
      ', '
      ORDER BY rank_order
    ) AS all_services_text
  FROM formatted_work_types
  -- Include all work types that have closed commercial value > 0
)

-- Final output in required format
SELECT 'Title Block' AS "content",
       'We estimate the commercial value of services requested and rendered. Volunteers provided at least ' ||
       aswt.all_services_text ||
       '. These estimates do not include work not entered into Crisis Cleanup.' AS "value"
FROM all_significant_work_types aswt;