-- Service Insights for Magazine Visualizations
-- Generates contextual insights and dynamic text for various chart types
-- Output: Three-column format with "Chart Title", "Insight", and "Asset Title"

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
-- Check county count to determine proportional area chart granularity level (same logic as proportional_area_chart.sql)
county_count_check AS (
  SELECT 
    COUNT(DISTINCT aw.county) AS total_counties
  FROM worksite_worksites aw
  INNER JOIN target_incident ti ON aw.incident_id = ti.id
  CROSS JOIN report_period rp
  WHERE aw.invalidated_at IS NULL
    AND aw.county IS NOT NULL
    AND aw.county != ''
    AND DATE(aw.created_at AT TIME ZONE 'UTC' AT TIME ZONE ti.timezone)
          BETWEEN rp.report_start_date AND rp.report_end_date
),
-- Use logic from incident_summary_worktypes.sql for work type stats
work_type_stats AS (
  SELECT 
    wwwtsp.work_type_key,
    COUNT(*) as total_count
  FROM worksite_worksites aw
  INNER JOIN target_incident ti ON aw.incident_id = ti.id
  CROSS JOIN report_period rp
  LEFT JOIN worksite_worksites_work_types_statuses_phases wwwtsp ON aw.id = wwwtsp.worksite_id
  WHERE aw.invalidated_at IS NULL
    AND wwwtsp.invalidated_at IS NULL
    AND wwwtsp.work_type_key IS NOT NULL
    AND wwwtsp.work_type_key NOT IN ('mold_remediation', 'rebuild', 'heating', 'shopping', 'report')
    AND DATE(aw.created_at AT TIME ZONE 'UTC' AT TIME ZONE ti.timezone)
          BETWEEN rp.report_start_date AND rp.report_end_date
  GROUP BY wwwtsp.work_type_key
  ORDER BY total_count DESC
),
total_work_types AS (
  SELECT SUM(total_count) AS grand_total
  FROM work_type_stats
),
work_type_percentages AS (
  SELECT 
    work_type_key,
    total_count,
    ROUND((total_count * 100.0) / twt.grand_total, 0) AS percentage
  FROM work_type_stats wts
  CROSS JOIN total_work_types twt
  ORDER BY total_count DESC
),
top_work_types AS (
  SELECT 
    STRING_AGG(
      CASE 
        WHEN work_type_key = 'debris' THEN percentage || '% were debris'
        WHEN work_type_key = 'mucb_bucb' THEN percentage || '% were muck outs'
        WHEN work_type_key = 'trees' THEN percentage || '% were trees' 
        WHEN work_type_key = 'tarp' THEN percentage || '% were tarps'
        ELSE percentage || '% were ' || REPLACE(work_type_key, '_', ' ')
      END, 
      ', ' 
      ORDER BY total_count DESC
    ) AS work_type_breakdown
  FROM work_type_percentages 
  WHERE percentage >= 4  -- Only include work types with 4% or more
),
-- Calculate SVI needs met percentage - actual cases helped vs total cases in vulnerable communities
svi_needs_met AS (
  SELECT
    ROUND(
      (COUNT(DISTINCT CASE 
        WHEN EXISTS (
          SELECT 1 FROM worksite_worksites_work_types_statuses_phases wwwtsp_help
          WHERE wwwtsp_help.worksite_id = aw.id
            AND wwwtsp_help.invalidated_at IS NULL
            AND wwwtsp_help.status_key LIKE 'closed%'
        ) THEN aw.id 
      END) * 100.0) / NULLIF(COUNT(DISTINCT aw.id), 0), 0
    ) AS avg_needs_met_percentage
  FROM worksite_worksites aw
  INNER JOIN target_incident ti ON aw.incident_id = ti.id
  CROSS JOIN report_period rp
  WHERE aw.invalidated_at IS NULL
    AND aw.svi IS NOT NULL
    AND aw.svi > 0.5  -- Focus on more vulnerable communities (SVI > 0.5)
    AND DATE(aw.created_at AT TIME ZONE 'UTC' AT TIME ZONE ti.timezone)
          BETWEEN rp.report_start_date AND rp.report_end_date
)

-- Final output in required format
SELECT 'Stacked Bar: Volunteer Impact by Work Type' AS "Chart Title",
       'Out of all work requested, ' || twt.work_type_breakdown || '.' AS "Insight",
       '11_cases_by_worktype.pdf' AS "Asset Title"
FROM top_work_types twt

UNION ALL

SELECT 'Proportional Area Chart: Counties/Zip Codes Most Affected' AS "Chart Title",
       CASE
         WHEN ccc.total_counties <= 4 THEN
           'Areas show the relative number of cases in each ZIP code. Larger squares mean more cases. The color indicates Percent Closed completion rates. The following pages include statistics for each county.'
         ELSE
           'Areas show the relative number of cases in each county. Larger squares mean more cases. The color indicates Percent Closed completion rates. The following pages include statistics for each county.'
       END AS "Insight",
       'proportional_area_chart.pdf' AS "Asset Title"
FROM county_count_check ccc

UNION ALL

SELECT 'Histogram: Needs Met by Social Vulnerability' AS "Chart Title",
       'On average, nearly ' || snm.avg_needs_met_percentage || '% of needs were met among more socially vulnerable communities.' AS "Insight",
       '12_needs_met_svi.pdf' AS "Asset Title"
FROM svi_needs_met snm

UNION ALL

SELECT 'Stacked Bar: Work type Closures of Total Requested' AS "Chart Title",
       'More vulnerable communities generally received more help than less vulnerable communities.' AS "Insight",
       '13_commercial_value_svi.pdf' AS "Asset Title";