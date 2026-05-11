-- Daily Hotline Calls Timeseries
-- Generates daily phone call counts over the analysis period for hotline_calls.pdf
-- Output: Two-column format with "creation_date" and "phone_calls"

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
date_range AS (
  -- Generates a series of all dates within the determined report period
  SELECT generate_series(
    rp.report_start_date,
    rp.report_end_date,
    INTERVAL '1 day'
  )::DATE AS creation_date
  FROM report_period rp
),
daily_calls AS (
  -- Count distinct phone calls per day using phone_inbound
  SELECT 
    DATE(pi.created_at AT TIME ZONE 'UTC' AT TIME ZONE ti.timezone) AS creation_date,
    COUNT(DISTINCT pi.session_id) AS phone_calls
  FROM phone_inbound pi
  INNER JOIN target_incident ti ON string_to_array('175', ',')::int[] && pi.incident_id
  CROSS JOIN report_period rp
  WHERE DATE(pi.created_at AT TIME ZONE 'UTC' AT TIME ZONE ti.timezone) 
        BETWEEN rp.report_start_date AND rp.report_end_date
  GROUP BY DATE(pi.created_at AT TIME ZONE 'UTC' AT TIME ZONE ti.timezone)
)

-- Final output with all dates in range (including zero-call days)
SELECT
  dr.creation_date,
  COALESCE(dc.phone_calls, 0) AS phone_calls
FROM date_range dr
LEFT JOIN daily_calls dc ON dr.creation_date = dc.creation_date
ORDER BY dr.creation_date;