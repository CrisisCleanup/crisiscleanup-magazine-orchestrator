-- Service Statistics for Magazine Layout
-- Output: Two-column format with "Stat Name" and "Value"
-- Provides closed commercial value of volunteer services

WITH target_incident AS (
  -- Standard multi-incident target incident selection
  SELECT
    id,
    start_at,
    timezone,
    incident_type,
    short_name,
    name,
    DATE(start_at AT TIME ZONE 'UTC' AT TIME ZONE timezone) AS configured_start_date_tz
  FROM incident_incidents
  WHERE id = ANY(string_to_array('175', ',')::int[])
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
closed_commercial_value AS (
  -- Calculate total closed commercial value using standardized methodology
  SELECT
    SUM(wwt.commercial_value * wws.completed_by_anybody) AS total_closed_value
  FROM worksite_worksites aw
  INNER JOIN target_incident ti ON aw.incident_id = ti.id
  CROSS JOIN report_period rp
  LEFT JOIN worksite_worksites_work_types_statuses_phases wwwtsp ON aw.id = wwwtsp.worksite_id
  LEFT JOIN worksite_work_statuses wws ON wwwtsp.status_key = wws.status
  LEFT JOIN worksite_work_types wwt ON wwwtsp.work_type_key = wwt.key
  WHERE wwwtsp.invalidated_at IS NULL
    AND aw.invalidated_at IS NULL
    AND DATE(aw.created_at AT TIME ZONE 'UTC' AT TIME ZONE ti.timezone)
          BETWEEN rp.report_start_date AND rp.report_end_date
)

-- Final output in required two-column format
SELECT 
  'Commercial Value of Volunteer Services' AS "Stat Name",
  CASE 
    WHEN ccv.total_closed_value >= 1000000 THEN 
      '$' || ROUND(ccv.total_closed_value / 1000000.0, 1) || 'M'
    WHEN ccv.total_closed_value >= 1000 THEN 
      '$' || ROUND(ccv.total_closed_value / 1000.0, 1) || 'k'
    ELSE 
      '$' || TO_CHAR(ROUND(ccv.total_closed_value), 'FM999,999,999')
  END AS "Value"
FROM closed_commercial_value ccv

UNION ALL

SELECT 
  'Commercial Value of Volunteer Services Daily' AS "Stat Name",
  CASE 
    WHEN (ccv.total_closed_value / NULLIF(rp.analysis_days, 0)) >= 1000000 THEN 
      '$' || ROUND((ccv.total_closed_value / NULLIF(rp.analysis_days, 0)) / 1000000.0, 1) || 'M'
    WHEN (ccv.total_closed_value / NULLIF(rp.analysis_days, 0)) >= 1000 THEN 
      '$' || ROUND((ccv.total_closed_value / NULLIF(rp.analysis_days, 0)) / 1000.0, 1) || 'k'
    ELSE 
      '$' || TO_CHAR(ROUND(ccv.total_closed_value / NULLIF(rp.analysis_days, 0)), 'FM999,999,999')
  END AS "Value"
FROM closed_commercial_value ccv
CROSS JOIN (
  SELECT (report_end_date - report_start_date + 1) AS analysis_days
  FROM report_period
) rp;