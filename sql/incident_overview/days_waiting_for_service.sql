-- Days Waiting for Service Analysis
-- Generates bar graph data showing cases by days from request to closure (0-30 days)
-- Output: Two-column format with "day" and "count"

WITH target_incident AS (
  -- Get target incident details for timezone and date filtering
  SELECT id, start_at, timezone, incident_type, short_name, name
  FROM incident_incidents
  WHERE id = ANY(string_to_array('175', ',')::int[])
),
report_period AS (
  -- Determine the report period for the target incidents (60 days from earliest start)
  SELECT
    MIN(DATE(ti.start_at AT TIME ZONE 'UTC' AT TIME ZONE ti.timezone)) AS report_start_date,
    (MIN(DATE(ti.start_at AT TIME ZONE 'UTC' AT TIME ZONE ti.timezone)) + INTERVAL '59 days')::DATE AS report_end_date,
    MIN(ti.timezone) AS timezone
  FROM target_incident ti
),
worksite_completion_times AS (
  -- Calculate days from worksite creation to work completion for each worksite
  SELECT 
    aw.id,
    aw.created_at,
    wwwtsp.created_at AS closed_at,
    EXTRACT(EPOCH FROM (wwwtsp.created_at - aw.created_at)) / 86400 AS days_to_close
  FROM worksite_worksites aw
  INNER JOIN target_incident ti ON aw.incident_id = ti.id
  CROSS JOIN report_period rp
  LEFT JOIN worksite_worksites_work_types_statuses_phases wwwtsp ON aw.id = wwwtsp.worksite_id
  WHERE aw.invalidated_at IS NULL
    AND wwwtsp.invalidated_at IS NULL
    AND wwwtsp.status_key LIKE 'closed%'  -- Only completed work
    AND DATE(aw.created_at AT TIME ZONE 'UTC' AT TIME ZONE rp.timezone)
          BETWEEN rp.report_start_date AND rp.report_end_date
    AND wwwtsp.created_at IS NOT NULL  -- Ensure we have a completion date
),
filtered_completion_times AS (
  -- Filter to only include cases that took 0-30 days to close
  SELECT 
    FLOOR(days_to_close)::INTEGER AS days_bucket
  FROM worksite_completion_times
  WHERE days_to_close >= 0 
    AND days_to_close <= 30
),
day_counts AS (
  -- Count cases by days (0-30)
  SELECT 
    days_bucket AS day,
    COUNT(*) AS count
  FROM filtered_completion_times
  GROUP BY days_bucket
),
all_days AS (
  -- Generate all days from 0 to 30 to ensure complete range
  SELECT generate_series(0, 30) AS day
)

-- Final output with complete day range (0-30)
SELECT 
  ad.day,
  COALESCE(dc.count, 0) AS count
FROM all_days ad
LEFT JOIN day_counts dc ON ad.day = dc.day
ORDER BY ad.day;