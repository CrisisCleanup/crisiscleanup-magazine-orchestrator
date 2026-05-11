-- State Summary Insights for Magazine State-Level Visualizations
-- Generates contextual insights and dynamic text for state-specific chart types
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
-- Check county count across entire incident to determine granularity level (consistent with other files)
incident_county_count_check AS (
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
state_list AS (
  -- Generate list of states from parameter
  SELECT TRIM(unnest(string_to_array('STATE_LIST_PLACEHOLDER', ','))) AS state_code
  WHERE 'STATE_LIST_PLACEHOLDER' IS NOT NULL
),
-- County count using geographic containment logic
state_county_counts AS (
  SELECT
    RIGHT(ll.name, 2) AS state_code,
    COUNT(DISTINCT ll.name) AS county_count
  FROM worksite_worksites aw
  INNER JOIN target_incident ti ON aw.incident_id = ti.id
  CROSS JOIN report_period rp
  LEFT JOIN location_locations ll ON (ST_Contains(ST_Multi(ll.poly), aw.location) OR ST_Contains(ST_Multi(ll.geom), aw.location))
  WHERE aw.invalidated_at IS NULL
    AND ll.type_id IN (SELECT id FROM location_types WHERE key = 'boundary_political_home_local_division')
    AND ll.created_by = 14
    AND DATE(aw.created_at AT TIME ZONE 'UTC' AT TIME ZONE ti.timezone)
          BETWEEN rp.report_start_date AND rp.report_end_date
    AND RIGHT(ll.name, 2) = ANY(string_to_array(REPLACE('STATE_LIST_PLACEHOLDER', ' ', ''), ','))
  GROUP BY RIGHT(ll.name, 2)
),
-- Case counting using county-based geographic filtering
state_case_counts AS (
  SELECT
    RIGHT(ll.name, 2) AS state_code,
    COUNT(DISTINCT aw.id) AS total_cases
  FROM worksite_worksites aw
  INNER JOIN target_incident ti ON aw.incident_id = ti.id
  CROSS JOIN report_period rp
  LEFT JOIN location_locations ll ON (ST_Contains(ST_Multi(ll.poly), aw.location) OR ST_Contains(ST_Multi(ll.geom), aw.location))
  WHERE aw.invalidated_at IS NULL
    AND ll.type_id IN (SELECT id FROM location_types WHERE key = 'boundary_political_home_local_division')
    AND ll.created_by = 14
    AND DATE(aw.created_at AT TIME ZONE 'UTC' AT TIME ZONE ti.timezone)
          BETWEEN rp.report_start_date AND rp.report_end_date
    AND RIGHT(ll.name, 2) = ANY(string_to_array(REPLACE('STATE_LIST_PLACEHOLDER', ' ', ''), ','))
  GROUP BY RIGHT(ll.name, 2)
),
-- Work type values using county-based geographic filtering
state_work_type_values AS (
  SELECT
    RIGHT(ll.name, 2) AS state_code,
    aw.id AS worksite_id,
    wwwtsp.work_type_key,
    wwt.commercial_value * (1 - wws.completed_by_anybody) AS open_value,
    wwt.commercial_value * wws.completed_by_anybody AS closed_value,
    wwt.commercial_value AS total_value,
    (wwwtsp.work_type_claimed_by IS NOT NULL) AS is_claimed,
    (wws.primary_state = 'open') AS is_open,
    wws.completed_by_anybody AS is_closed
  FROM worksite_worksites aw
  INNER JOIN target_incident ti ON aw.incident_id = ti.id
  CROSS JOIN report_period rp
  LEFT JOIN location_locations ll ON (ST_Contains(ST_Multi(ll.poly), aw.location) OR ST_Contains(ST_Multi(ll.geom), aw.location))
  LEFT JOIN worksite_worksites_work_types_statuses_phases wwwtsp ON aw.id = wwwtsp.worksite_id
  LEFT JOIN worksite_work_statuses wws ON wwwtsp.status_key = wws.status
  LEFT JOIN worksite_work_types wwt ON wwwtsp.work_type_key = wwt.key
  WHERE wwwtsp.invalidated_at IS NULL
    AND aw.invalidated_at IS NULL
    AND ll.type_id IN (SELECT id FROM location_types WHERE key = 'boundary_political_home_local_division')
    AND ll.created_by = 14
    AND DATE(aw.created_at AT TIME ZONE 'UTC' AT TIME ZONE ti.timezone)
          BETWEEN rp.report_start_date AND rp.report_end_date
    AND RIGHT(ll.name, 2) = ANY(string_to_array(REPLACE('STATE_LIST_PLACEHOLDER', ' ', ''), ','))
),
-- State worksite ratios
state_worksite_ratios AS (
  SELECT
    state_code,
    worksite_id,
    SUM(open_value) FILTER (WHERE is_claimed AND is_open) AS open_claimed_value,
    SUM(open_value) FILTER (WHERE NOT is_claimed AND is_open) AS open_unclaimed_value,
    SUM(closed_value) AS total_closed_value,
    SUM(total_value) AS total_worksite_value
  FROM state_work_type_values
  GROUP BY state_code, worksite_id
),
-- State case status stats
state_case_status_stats AS (
  SELECT
    state_code,
    COUNT(worksite_id) AS total_cases,
    ROUND(COALESCE(SUM(total_closed_value / NULLIF(total_worksite_value, 0)), 0)) AS closed_cases,
    ROUND(COALESCE(SUM(open_claimed_value / NULLIF(total_worksite_value, 0)), 0)) AS claimed_cases,
    ROUND(COALESCE(SUM(open_unclaimed_value / NULLIF(total_worksite_value, 0)), 0)) AS open_cases
  FROM state_worksite_ratios
  GROUP BY state_code
),
-- State work type closure stats (matching donut chart calculation exactly: closed / (closed + open claimed + open unclaimed))
state_work_type_closures AS (
  SELECT 
    state_code,
    work_type_key,
    SUM(closed_value / NULLIF(total_value, 0)) as precise_closed_count,  -- Closed fractional values
    SUM(closed_value / NULLIF(total_value, 0)) + 
    SUM(CASE WHEN is_claimed AND is_open THEN open_value / NULLIF(total_value, 0) ELSE 0 END) + 
    SUM(CASE WHEN NOT is_claimed AND is_open THEN open_value / NULLIF(total_value, 0) ELSE 0 END) as precise_total_count,  -- Total work type values like donut chart
    ROUND(SUM(closed_value / NULLIF(total_value, 0)), 1) as closed_count,  -- Use fractional completion like donut chart
    ROUND(SUM(closed_value / NULLIF(total_value, 0)) + 
          SUM(CASE WHEN is_claimed AND is_open THEN open_value / NULLIF(total_value, 0) ELSE 0 END) + 
          SUM(CASE WHEN NOT is_claimed AND is_open THEN open_value / NULLIF(total_value, 0) ELSE 0 END), 1) as total_count,
    ROUND((SUM(closed_value / NULLIF(total_value, 0)) * 100.0) / 
          NULLIF(SUM(closed_value / NULLIF(total_value, 0)) + 
                 SUM(CASE WHEN is_claimed AND is_open THEN open_value / NULLIF(total_value, 0) ELSE 0 END) + 
                 SUM(CASE WHEN NOT is_claimed AND is_open THEN open_value / NULLIF(total_value, 0) ELSE 0 END), 0), 0) AS closure_percentage
  FROM state_work_type_values
  WHERE work_type_key IS NOT NULL
    AND work_type_key NOT IN ('mold_remediation', 'rebuild', 'heating')
  GROUP BY state_code, work_type_key
),
-- Top work types by state
state_top_work_types AS (
  SELECT 
    state_code,
    STRING_AGG(
      CASE 
        WHEN work_type_key = 'debris' THEN 
          CASE WHEN closed_count = ROUND(closed_count) THEN ROUND(closed_count)::text ELSE closed_count::text END || ' debris cases'
        WHEN work_type_key = 'mucb' THEN 
          CASE WHEN closed_count = ROUND(closed_count) THEN ROUND(closed_count)::text ELSE closed_count::text END || ' muck out cases'
        WHEN work_type_key = 'trees' THEN 
          CASE WHEN closed_count = ROUND(closed_count) THEN ROUND(closed_count)::text ELSE closed_count::text END || ' tree cases' 
        WHEN work_type_key = 'tarp' THEN 
          CASE WHEN closed_count = ROUND(closed_count) THEN ROUND(closed_count)::text ELSE closed_count::text END || ' tarp cases'
        ELSE 
          CASE WHEN closed_count = ROUND(closed_count) THEN ROUND(closed_count)::text ELSE closed_count::text END || ' ' || REPLACE(work_type_key, '_', ' ') || ' cases'
      END, 
      ', ' 
      ORDER BY closed_count DESC
    ) AS work_type_details,
    STRING_AGG(
      CASE 
        WHEN work_type_key = 'debris' THEN 
          ROUND((precise_closed_count * 100.0) / NULLIF(precise_total_count, 0), 0) || '% of debris cases'
        WHEN work_type_key = 'mucb' THEN 
          ROUND((precise_closed_count * 100.0) / NULLIF(precise_total_count, 0), 0) || '% of muck out cases'
        WHEN work_type_key = 'trees' THEN 
          ROUND((precise_closed_count * 100.0) / NULLIF(precise_total_count, 0), 0) || '% of tree cases' 
        WHEN work_type_key = 'tarp' THEN 
          ROUND((precise_closed_count * 100.0) / NULLIF(precise_total_count, 0), 0) || '% of tarp cases'
        ELSE 
          ROUND((precise_closed_count * 100.0) / NULLIF(precise_total_count, 0), 0) || '% of ' || REPLACE(work_type_key, '_', ' ') || ' cases'
      END, 
      ', ' 
      ORDER BY closed_count DESC
    ) AS work_type_percentages
  FROM (
    SELECT 
      state_code,
      work_type_key,
      closed_count,
      precise_closed_count,
      precise_total_count,
      closure_percentage,
      ROW_NUMBER() OVER (PARTITION BY state_code ORDER BY closed_count DESC) as rank
    FROM state_work_type_closures
    WHERE closed_count > 0  -- Only include work types that have some closures
  ) ranked_work_types
  WHERE rank <= 4
  GROUP BY state_code
),
-- Organization stats using 30-day period logic
org_30_day_period AS (
  SELECT
    ti.timezone,
    (SELECT MIN(analysis_start) FROM incident_analysis_periods) AS report_start_date,
    ((SELECT MIN(analysis_start) FROM incident_analysis_periods) + INTERVAL '29 days')::DATE AS report_end_date
  FROM target_incident ti
  LIMIT 1
),
-- Get all organizations active in each state across full 60-day period
state_all_orgs AS (
  SELECT DISTINCT q.organization_id, q.state_code
  FROM (
    SELECT ww.reported_by AS organization_id, RIGHT(ll.name, 2) AS state_code
    FROM worksite_worksites AS ww
    INNER JOIN target_incident ti ON ti.id = ww.incident_id
    LEFT JOIN location_locations ll ON (ST_Contains(ST_Multi(ll.poly), ww.location) OR ST_Contains(ST_Multi(ll.geom), ww.location))
    CROSS JOIN report_period rp
    WHERE ww.invalidated_at IS NULL
      AND ll.type_id IN (SELECT id FROM location_types WHERE key = 'boundary_political_home_local_division')
      AND ll.created_by = 14
      AND DATE(ww.created_at AT TIME ZONE 'UTC' AT TIME ZONE ti.timezone) BETWEEN rp.report_start_date AND rp.report_end_date

    UNION ALL

    SELECT w.work_type_claimed_by AS organization_id, RIGHT(ll.name, 2) AS state_code
    FROM worksite_worksites_work_types_statuses_phases AS w
    INNER JOIN target_incident ti ON ti.id = w.incident_id
    INNER JOIN worksite_worksites ww ON w.worksite_id = ww.id
    LEFT JOIN location_locations ll ON (ST_Contains(ST_Multi(ll.poly), ww.location) OR ST_Contains(ST_Multi(ll.geom), ww.location))
    CROSS JOIN report_period rp
    WHERE w.invalidated_at IS NULL
      AND ww.invalidated_at IS NULL
      AND ll.type_id IN (SELECT id FROM location_types WHERE key = 'boundary_political_home_local_division')
      AND ll.created_by = 14
      AND DATE(w.created_at AT TIME ZONE 'UTC' AT TIME ZONE ti.timezone) BETWEEN rp.report_start_date AND rp.report_end_date

    UNION ALL

    SELECT uu.organization_id, RIGHT(ll.name, 2) AS state_code
    FROM worksite_worksites_work_types_statuses_phases AS w
    INNER JOIN target_incident ti ON ti.id = w.incident_id
    INNER JOIN worksite_worksites ww ON w.worksite_id = ww.id
    LEFT JOIN location_locations ll ON (ST_Contains(ST_Multi(ll.poly), ww.location) OR ST_Contains(ST_Multi(ll.geom), ww.location))
    CROSS JOIN report_period rp
    LEFT JOIN user_users AS uu ON w.work_type_created_by = uu.id
    WHERE w.invalidated_at IS NULL
      AND ww.invalidated_at IS NULL
      AND ll.type_id IN (SELECT id FROM location_types WHERE key = 'boundary_political_home_local_division')
      AND ll.created_by = 14
      AND DATE(w.created_at AT TIME ZONE 'UTC' AT TIME ZONE ti.timezone) BETWEEN rp.report_start_date AND rp.report_end_date

    UNION ALL

    -- Phone organizations are attributed to all states since calls aren't geographically specific
    SELECT uu.organization_id, sl.state_code
    FROM phone_inbound AS pi
    INNER JOIN target_incident ti ON ti.id = ANY(pi.incident_id)
    CROSS JOIN report_period rp
    CROSS JOIN state_list sl
    LEFT JOIN user_users AS uu ON pi.created_by = uu.id
    WHERE DATE(pi.created_at AT TIME ZONE 'UTC' AT TIME ZONE ti.timezone) BETWEEN rp.report_start_date AND rp.report_end_date
  ) q
  WHERE q.organization_id IS NOT NULL AND q.organization_id <> 89 AND q.state_code IS NOT NULL
),
-- Get organizations that HELPED (claimed work types) in each state during first 30 days
state_orgs_that_helped AS (
  SELECT DISTINCT w.work_type_claimed_by AS organization_id, RIGHT(ll.name, 2) AS state_code
  FROM worksite_worksites_work_types_statuses_phases AS w
  INNER JOIN target_incident ti ON ti.id = w.incident_id
  INNER JOIN worksite_worksites ww ON w.worksite_id = ww.id
  LEFT JOIN location_locations ll ON (ST_Contains(ST_Multi(ll.poly), ww.location) OR ST_Contains(ST_Multi(ll.geom), ww.location))
  CROSS JOIN org_30_day_period rp
  WHERE w.invalidated_at IS NULL
    AND ww.invalidated_at IS NULL
    AND ll.type_id IN (SELECT id FROM location_types WHERE key = 'boundary_political_home_local_division')
    AND ll.created_by = 14
    AND w.work_type_claimed_by IS NOT NULL
    AND DATE(w.created_at AT TIME ZONE 'UTC' AT TIME ZONE ti.timezone) BETWEEN rp.report_start_date AND rp.report_end_date
    AND w.work_type_claimed_by <> 89
    AND RIGHT(ll.name, 2) IS NOT NULL
),
-- Calculate statistics per state
state_organization_stats AS (
  SELECT
    sl.state_code,
    COUNT(DISTINCT all_orgs.organization_id) AS active_orgs,
    COUNT(DISTINCT helped_orgs.organization_id) AS orgs_that_helped
  FROM state_list sl
  LEFT JOIN state_all_orgs all_orgs ON all_orgs.state_code = sl.state_code
  LEFT JOIN state_orgs_that_helped helped_orgs ON helped_orgs.state_code = sl.state_code
  GROUP BY sl.state_code
),
-- Combined state stats
state_combined_stats AS (
  SELECT
    sl.state_code,
    COALESCE(scc.county_count, 0) AS county_count,
    COALESCE(sccs.total_cases, 0) AS total_cases,
    COALESCE(sccs.closed_cases, 0) AS closed_cases,
    COALESCE(sccs.claimed_cases, 0) AS claimed_cases,
    COALESCE(sccs.open_cases, 0) AS open_cases,
    COALESCE(swt.work_type_details, 'no work types closed') AS work_type_details,
    COALESCE(swt.work_type_percentages, 'no work type percentages available') AS work_type_percentages,
    COALESCE(sos.active_orgs, 0) AS active_orgs,
    COALESCE(sos.orgs_that_helped, 0) AS orgs_that_helped
  FROM state_list sl
  LEFT JOIN state_county_counts scc ON sl.state_code = scc.state_code
  LEFT JOIN state_case_status_stats sccs ON sl.state_code = sccs.state_code
  LEFT JOIN state_top_work_types swt ON sl.state_code = swt.state_code
  LEFT JOIN state_organization_stats sos ON sl.state_code = sos.state_code
),
incident_name_formatted AS (
  SELECT 
    COALESCE(ti.name, ti.short_name) AS incident_display_name
  FROM target_incident ti
  LIMIT 1
)

-- Final output in required format
SELECT
  scs.state_code || '_Proportional Area Chart: Counties/Zip Codes Most Affected' AS "Chart Title",
  CASE
    WHEN iccc.total_counties <= 4 THEN
      'Areas show the relative number of cases in each ZIP code. Larger squares mean more damage. The color indicates completion rates. This report includes statistics for each county.'
    ELSE
      'Areas show the relative number of cases in each county. Larger squares mean more damage. The color indicates completion rates. This report includes statistics for each county.'
  END AS "Insight",
  'proportional_area_chart.pdf' AS "Asset Title"
FROM state_combined_stats scs
CROSS JOIN incident_county_count_check iccc

UNION ALL

SELECT 
  scs.state_code || '_Area Graph: Work type Closures over time' AS "Chart Title",
  'Volunteers closed ' || scs.work_type_details || '.' AS "Insight",
  '11_cases_by_worktype.pdf' AS "Asset Title"
FROM state_combined_stats scs

UNION ALL

SELECT 
  scs.state_code || '_Histogram: Needs Met by Social Vulnerability' AS "Chart Title",
  'More vulnerable communities generally received more help than less vulnerable communities.' AS "Insight",
  '12_needs_met_svi.pdf' AS "Asset Title"
FROM state_combined_stats scs

UNION ALL

SELECT 
  scs.state_code || '_Area Graph: Cases by Status' AS "Chart Title",
  'This incident had ' || TO_CHAR(scs.total_cases, 'FM999,999') || ' cases total. ' ||
  TO_CHAR(scs.closed_cases, 'FM999,999') || ' were closed, ' ||
  TO_CHAR(scs.claimed_cases, 'FM999,999') || ' were claimed but not closed, and ' ||
  TO_CHAR(scs.open_cases, 'FM999,999') || ' remained open.' AS "Insight",
  '6_cases_by_status.pdf' AS "Asset Title"
FROM state_combined_stats scs

UNION ALL

SELECT
  scs.state_code || '_Area Graph: Daily Active Organizations' AS "Chart Title",
  CASE
    WHEN scs.active_orgs = 0 THEN 'No organizations were active during this response.'
    ELSE ROUND((scs.orgs_that_helped * 100.0) / NULLIF(scs.active_orgs, 0), 0) || '% of ' ||
         scs.active_orgs || ' active organizations using Crisis Cleanup in this state helped someone by ' ||
         TO_CHAR((SELECT report_end_date FROM org_30_day_period), 'FMMonth DD, YYYY') || '.'
  END AS "Insight",
  '9_daily_active_organizations.pdf' AS "Asset Title"
FROM state_combined_stats scs
CROSS JOIN incident_name_formatted inf

UNION ALL

SELECT 
  scs.state_code || '_Area Graph: Work type Closures over time' AS "Chart Title",
  'Volunteers closed ' || scs.work_type_percentages || '.' AS "Insight",
  '7_worktype_closures.pdf' AS "Asset Title"
FROM state_combined_stats scs

ORDER BY
  1;  -- Sort by Chart Title (which starts with state code, naturally groups by state)