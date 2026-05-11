-- Volunteer Insights for Magazine Visualizations
-- Generates contextual insights and dynamic text for various chart types using established logic patterns
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
households_helped_60_day AS (
  -- 60-day households helped calculation (same period as other queries)
  -- Use geographic filtering instead of aw.state for consistency with other state-level queries
  SELECT 
    COUNT(DISTINCT aw.id) AS total_households_requesting_help,
    COUNT(DISTINCT CASE 
      WHEN EXISTS (
        SELECT 1 FROM worksite_worksites_work_types_statuses_phases wwwtsp_help
        WHERE wwwtsp_help.worksite_id = aw.id
          AND wwwtsp_help.invalidated_at IS NULL
          AND wwwtsp_help.status_key LIKE 'closed%'
      ) THEN aw.id 
    END) AS households_that_received_help,
    ROUND(
      (COUNT(DISTINCT CASE 
        WHEN EXISTS (
          SELECT 1 FROM worksite_worksites_work_types_statuses_phases wwwtsp_help
          WHERE wwwtsp_help.worksite_id = aw.id
            AND wwwtsp_help.invalidated_at IS NULL
            AND wwwtsp_help.status_key LIKE 'closed%'
        ) THEN aw.id 
      END) * 100.0) / NULLIF(COUNT(DISTINCT aw.id), 0), 0
    ) AS help_percentage
  FROM worksite_worksites aw
  INNER JOIN target_incident ti ON aw.incident_id = ti.id
  CROSS JOIN report_period rp
  LEFT JOIN location_locations ll ON (ST_Contains(ST_Multi(ll.poly), aw.location) OR ST_Contains(ST_Multi(ll.geom), aw.location))
  WHERE aw.invalidated_at IS NULL
    AND DATE(aw.created_at AT TIME ZONE 'UTC' AT TIME ZONE ti.timezone)
          BETWEEN rp.report_start_date AND rp.report_end_date
    AND (
      'STATE_LIST_PLACEHOLDER' IS NULL 
      OR (
        ll.type_id IN (SELECT id FROM location_types WHERE key = 'boundary_political_home_local_division')
        AND ll.created_by = 14
        AND RIGHT(ll.name, 2) = ANY(string_to_array(REPLACE('STATE_LIST_PLACEHOLDER', ' ', ''), ','))
      )
      OR aw.state = ANY(string_to_array(REPLACE('STATE_LIST_PLACEHOLDER', ' ', ''), ','))
    )
),
incident_states AS (
  -- State counting respecting state list parameter, using geographic filtering for consistency
  SELECT 
    CASE 
      WHEN 'STATE_LIST_PLACEHOLDER' IS NULL THEN 
        COUNT(DISTINCT COALESCE(RIGHT(ll.name, 2), aw.state))
      ELSE 
        ARRAY_LENGTH(string_to_array(REPLACE('STATE_LIST_PLACEHOLDER', ' ', ''), ','), 1)
    END AS state_count,
    CASE 
      WHEN 'STATE_LIST_PLACEHOLDER' IS NULL THEN 
        STRING_AGG(DISTINCT COALESCE(RIGHT(ll.name, 2), aw.state), ', ' ORDER BY COALESCE(RIGHT(ll.name, 2), aw.state))
      ELSE 
        'STATE_LIST_PLACEHOLDER'
    END AS state_list
  FROM worksite_worksites aw
  INNER JOIN target_incident ti ON aw.incident_id = ti.id
  CROSS JOIN report_period rp
  LEFT JOIN location_locations ll ON (ST_Contains(ST_Multi(ll.poly), aw.location) OR ST_Contains(ST_Multi(ll.geom), aw.location))
                                  AND ll.type_id IN (SELECT id FROM location_types WHERE key = 'boundary_political_home_local_division')
                                  AND ll.created_by = 14
  WHERE aw.invalidated_at IS NULL
    AND (COALESCE(RIGHT(ll.name, 2), aw.state) IS NOT NULL)
    AND (COALESCE(RIGHT(ll.name, 2), aw.state) != '')
    AND LENGTH(COALESCE(RIGHT(ll.name, 2), aw.state)) = 2
    AND COALESCE(RIGHT(ll.name, 2), aw.state) ~ '^[A-Z]{2}$'
    AND DATE(aw.created_at AT TIME ZONE 'UTC' AT TIME ZONE ti.timezone)
          BETWEEN rp.report_start_date AND rp.report_end_date
    AND (
      'STATE_LIST_PLACEHOLDER' IS NULL 
      OR COALESCE(RIGHT(ll.name, 2), aw.state) = ANY(string_to_array(REPLACE('STATE_LIST_PLACEHOLDER', ' ', ''), ','))
    )
),
-- Use STANDARDIZED logic from incident_summary_overall.sql for case status
work_type_values AS (
  SELECT
    aw.id AS worksite_id,
    wwt.commercial_value * (1 - wws.completed_by_anybody) AS open_value,
    wwt.commercial_value * wws.completed_by_anybody AS closed_value,
    wwt.commercial_value AS total_value,
    (wwwtsp.work_type_claimed_by IS NOT NULL) AS is_claimed,
    (wws.primary_state = 'open') AS is_open
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
),
worksite_ratios AS (
  SELECT
    worksite_id,
    SUM(open_value) FILTER (WHERE is_claimed AND is_open) AS open_claimed_value,
    SUM(open_value) FILTER (WHERE NOT is_claimed AND is_open) AS open_unclaimed_value,
    SUM(closed_value) AS total_closed_value,
    SUM(total_value) AS total_worksite_value
  FROM work_type_values
  GROUP BY worksite_id
),
case_status_stats AS (
  SELECT
    COUNT(worksite_id) AS total_cases,
    ROUND(COALESCE(SUM(total_closed_value / NULLIF(total_worksite_value, 0)), 0)) AS closed_cases,
    ROUND(COALESCE(SUM(open_claimed_value / NULLIF(total_worksite_value, 0)), 0)) AS claimed_cases,
    ROUND(COALESCE(SUM(open_unclaimed_value / NULLIF(total_worksite_value, 0)), 0)) AS open_cases
  FROM worksite_ratios
),
-- Use EXACT logic from incident_summary_worktypes.sql for work type stats
work_type_stats AS (
  SELECT 
    wwwtsp.work_type_key,
    COUNT(*) as closed_count
  FROM worksite_worksites aw
  INNER JOIN target_incident ti ON aw.incident_id = ti.id
  CROSS JOIN report_period rp
  LEFT JOIN worksite_worksites_work_types_statuses_phases wwwtsp ON aw.id = wwwtsp.worksite_id
  LEFT JOIN worksite_work_statuses wws ON wwwtsp.status_key = wws.status
  WHERE aw.invalidated_at IS NULL
    AND wwwtsp.invalidated_at IS NULL
    AND wws.completed_by_anybody > 0  -- Only closed work
    AND wwwtsp.work_type_key IS NOT NULL
    AND wwwtsp.work_type_key NOT IN ('mold_remediation', 'rebuild', 'heating', 'shopping', 'report')
    AND DATE(aw.created_at AT TIME ZONE 'UTC' AT TIME ZONE ti.timezone)
          BETWEEN rp.report_start_date AND rp.report_end_date
  GROUP BY wwwtsp.work_type_key
  ORDER BY closed_count DESC
),
predominant_work_types AS (
  SELECT 
    work_type_key,
    closed_count,
    ROW_NUMBER() OVER (ORDER BY closed_count DESC) as rank
  FROM work_type_stats
),
top_work_types AS (
  SELECT 
    STRING_AGG(
      CASE 
        WHEN work_type_key = 'debris' THEN 'debris'
        WHEN work_type_key = 'mucb_bucb' THEN 'muck outs'
        WHEN work_type_key = 'trees' THEN 'trees' 
        WHEN work_type_key = 'tarp' THEN 'tarps'
        ELSE REPLACE(work_type_key, '_', ' ')
      END, 
      ', ' 
      ORDER BY closed_count DESC
    ) AS work_type_list,
    ROUND(
      (COUNT(*) * 100.0) / (SELECT COUNT(*) FROM work_type_stats), 0
    ) AS predominant_percentage
  FROM predominant_work_types 
  WHERE rank <= 4
),
-- Organization stats: 60-day denominator (all active orgs) vs 30-day numerator (orgs that helped)
org_30_day_period AS (
  SELECT
    ti.timezone,
    (SELECT MIN(analysis_start) FROM incident_analysis_periods) AS report_start_date,
    ((SELECT MIN(analysis_start) FROM incident_analysis_periods) + INTERVAL '29 days')::DATE AS report_end_date
  FROM target_incident ti
  LIMIT 1
),
active_organizations AS (
  SELECT DISTINCT q.organization_id
  FROM (
    SELECT ww.reported_by AS organization_id
    FROM worksite_worksites AS ww
    INNER JOIN target_incident ti ON ti.id = ww.incident_id
    CROSS JOIN report_period rp  -- Use full 60-day period for denominator
    WHERE ww.invalidated_at IS NULL
      AND DATE(ww.created_at AT TIME ZONE 'UTC' AT TIME ZONE ti.timezone) BETWEEN rp.report_start_date AND rp.report_end_date

    UNION ALL

    SELECT w.work_type_claimed_by AS organization_id
    FROM worksite_worksites_work_types_statuses_phases AS w
    INNER JOIN target_incident ti ON ti.id = w.incident_id
    CROSS JOIN report_period rp  -- Use full 60-day period for denominator
    WHERE DATE(w.created_at AT TIME ZONE 'UTC' AT TIME ZONE ti.timezone) BETWEEN rp.report_start_date AND rp.report_end_date

    UNION ALL

    SELECT uu.organization_id
    FROM worksite_worksites_work_types_statuses_phases AS w
    INNER JOIN target_incident ti ON ti.id = w.incident_id
    CROSS JOIN report_period rp  -- Use full 60-day period for denominator
    LEFT JOIN user_users AS uu ON w.work_type_created_by = uu.id
    WHERE DATE(w.created_at AT TIME ZONE 'UTC' AT TIME ZONE ti.timezone) BETWEEN rp.report_start_date AND rp.report_end_date

    UNION ALL

    SELECT uu.organization_id
    FROM phone_inbound AS pi
    INNER JOIN target_incident ti ON ti.id = ANY(pi.incident_id)
    CROSS JOIN report_period rp  -- Use full 60-day period for denominator
    LEFT JOIN user_users AS uu ON pi.created_by = uu.id
    WHERE DATE(pi.created_at AT TIME ZONE 'UTC' AT TIME ZONE ti.timezone) BETWEEN rp.report_start_date AND rp.report_end_date
  ) q
  WHERE q.organization_id IS NOT NULL AND q.organization_id <> 89
),
organization_stats AS (
  SELECT 
    COUNT(DISTINCT ao.organization_id) AS active_orgs,
    COUNT(DISTINCT CASE 
      WHEN EXISTS (
        SELECT 1 FROM worksite_worksites_work_types_statuses_phases wwwtsp2
        CROSS JOIN org_30_day_period rp  -- Use 30-day period for numerator
        WHERE wwwtsp2.work_type_claimed_by = ao.organization_id
          AND wwwtsp2.invalidated_at IS NULL
          AND DATE(wwwtsp2.created_at AT TIME ZONE 'UTC' AT TIME ZONE rp.timezone) BETWEEN rp.report_start_date AND rp.report_end_date
      ) THEN ao.organization_id 
    END) AS orgs_that_helped
  FROM active_organizations ao
),
incident_name_formatted AS (
  SELECT 
    COALESCE(ti.name, ti.short_name) AS incident_display_name,
    ti.incident_type
  FROM target_incident ti
  LIMIT 1
)

-- Final output in required format
SELECT 'Case Overview Insight (middle-left)' AS "Chart Title",
       'The ' || 
       inf.incident_display_name || 
       ' response spanned ' ||
       CASE 
         WHEN ins.state_count = 1 THEN 'one state'
         WHEN ins.state_count = 2 THEN 'two states'  
         WHEN ins.state_count = 3 THEN 'three states'
         WHEN ins.state_count = 4 THEN 'four states'
         WHEN ins.state_count = 5 THEN 'five states'
         ELSE ins.state_count::text || ' states'
       END ||
       ' and caused significant damage to homes.

Crisis Cleanup helps volunteers help their neighbors with unskilled labor like removing mud and debris (muck out), moving debris to the curb, tarping roofs, and clearing downed trees. These statistics are for the ' ||
       inf.incident_display_name || '.' AS "Insight",
       '' AS "Asset Title"
FROM incident_name_formatted inf
CROSS JOIN incident_states ins

UNION ALL

SELECT 'Stats Insight (bottom-right)' AS "Chart Title",
       'Crisis Cleanup works with national nonprofits, local churches, mutual aid groups, and community-based organizations. We also coordinate with local, state, and federal government partners. ' ||
       hhs.help_percentage || '% of households received some help in the first 60 days.' AS "Insight",
       '' AS "Asset Title"
FROM households_helped_60_day hhs

UNION ALL

SELECT 'Donut: Work Type Status' AS "Chart Title",
       twt.predominant_percentage || '% of work types that were closed are related to ' || twt.work_type_list || '.' AS "Insight",
       '{work_type}_Donut_plot.pdf' AS "Asset Title"
FROM top_work_types twt

UNION ALL

SELECT 'Area Graph: Cases by Status' AS "Chart Title",
       'This incident had ' || TO_CHAR(css.total_cases, 'FM999,999') || ' cases total. ' ||
       TO_CHAR(css.closed_cases, 'FM999,999') || ' were closed, ' ||
       TO_CHAR(css.claimed_cases, 'FM999,999') || ' were claimed but not closed, and ' ||
       TO_CHAR(css.open_cases, 'FM999,999') || ' remained open. A case is also called a worksite. The graph below breaks out the green section.' AS "Insight",
       '6_cases_by_status.pdf' AS "Asset Title"
FROM case_status_stats css

UNION ALL

SELECT 'Area Graph: Work type Closures over time' AS "Chart Title",
       'Volunteers closed work types across multiple categories. One case may have many work types, which is why there are more closed work types overall than cases.' AS "Insight",
       '7_worktype_closures.pdf' AS "Asset Title"

UNION ALL

SELECT 'Area Graph: Volunteer Engagement' AS "Chart Title",
       'Volunteers typically engage for two weeks after a disaster. However, a significant number of volunteers worked for more than 4 weeks after this incident.' AS "Insight",
       '8_volunteer_engagement.pdf' AS "Asset Title"

UNION ALL

SELECT 'Area Graph: Daily Active Organizations' AS "Chart Title",
       ROUND((os.orgs_that_helped * 100.0) / NULLIF(os.active_orgs, 0), 0) || '% of ' || 
       os.active_orgs || ' active organizations using Crisis Cleanup during the ' ||
       inf.incident_display_name || ' response helped someone by ' ||
       TO_CHAR(op.report_end_date, 'FMMonth DD, YYYY') || '.' AS "Insight",
       '9_daily_active_organizations.pdf' AS "Asset Title"
FROM organization_stats os
CROSS JOIN incident_name_formatted inf
CROSS JOIN org_30_day_period op

UNION ALL

SELECT 'Histogram: Days Waiting for Service' AS "Chart Title",
       'Of those who received help, the vast majority were helped within 14 days of asking.' AS "Insight",
       'days_waiting_for_service.pdf' AS "Asset Title";