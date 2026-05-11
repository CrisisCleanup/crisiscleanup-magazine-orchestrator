-- State Summary Statistics for Magazine Layout
-- Output: Two-column format with "Stat Name" and "Value" for each state in state list
-- Generates separate rows for each state specified in --state-list parameter

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
state_list AS (
  -- Generate list of states from parameter
  SELECT TRIM(unnest(string_to_array('STATE_LIST_PLACEHOLDER', ','))) AS state_code
  WHERE 'STATE_LIST_PLACEHOLDER' IS NOT NULL
),
-- Commercial value calculation using county-based geographic filtering
state_commercial_value AS (
  SELECT
    RIGHT(ll.name, 2) AS state_code,
    SUM(wwt.commercial_value * wws.completed_by_anybody) AS closed_commercial_value
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
  GROUP BY RIGHT(ll.name, 2)
),
-- County counting using geographic containment logic
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
-- Organization counting using geographic filtering (matching volunteer_stat.sql logic)
state_responding_organizations AS (
  SELECT
    RIGHT(ll.name, 2) AS state_code,
    COUNT(DISTINCT ooi.organization_id) AS responding_orgs
  FROM worksite_worksites aw
  INNER JOIN target_incident ti ON aw.incident_id = ti.id
  CROSS JOIN report_period rp
  LEFT JOIN location_locations ll ON (ST_Contains(ST_Multi(ll.poly), aw.location) OR ST_Contains(ST_Multi(ll.geom), aw.location))
  INNER JOIN organization_organizations_incidents ooi ON ooi.incident_id = ti.id
  WHERE aw.invalidated_at IS NULL
    AND ooi.approved_at IS NOT NULL
    AND ooi.invalidated_at IS NULL
    AND ll.type_id IN (SELECT id FROM location_types WHERE key = 'boundary_political_home_local_division')
    AND ll.created_by = 14
    AND DATE(aw.created_at AT TIME ZONE 'UTC' AT TIME ZONE ti.timezone)
          BETWEEN rp.report_start_date AND rp.report_end_date
    AND RIGHT(ll.name, 2) = ANY(string_to_array(REPLACE('STATE_LIST_PLACEHOLDER', ' ', ''), ','))
  GROUP BY RIGHT(ll.name, 2)
),
-- Households helped calculation using county-based geographic filtering (matching volunteer_stat.sql logic)
state_households_helped AS (
  SELECT
    RIGHT(ll.name, 2) AS state_code,
    COUNT(DISTINCT aw.id) AS households_helped
  FROM worksite_worksites aw
  INNER JOIN target_incident ti ON aw.incident_id = ti.id
  CROSS JOIN report_period rp
  LEFT JOIN location_locations ll ON (ST_Contains(ST_Multi(ll.poly), aw.location) OR ST_Contains(ST_Multi(ll.geom), aw.location))
  LEFT JOIN worksite_worksites_work_types_statuses_phases wwwtsp ON aw.id = wwwtsp.worksite_id
  LEFT JOIN worksite_work_statuses wws ON wwwtsp.status_key = wws.status
  WHERE aw.invalidated_at IS NULL
    AND wwwtsp.invalidated_at IS NULL
    AND wws.completed_by_anybody > 0  -- Only completed/closed work (matches volunteer_stat.sql)
    AND ll.type_id IN (SELECT id FROM location_types WHERE key = 'boundary_political_home_local_division')
    AND ll.created_by = 14
    AND DATE(aw.created_at AT TIME ZONE 'UTC' AT TIME ZONE ti.timezone)
          BETWEEN rp.report_start_date AND rp.report_end_date
    AND RIGHT(ll.name, 2) = ANY(string_to_array(REPLACE('STATE_LIST_PLACEHOLDER', ' ', ''), ','))
  GROUP BY RIGHT(ll.name, 2)
),
-- Combine all state statistics
state_stats_combined AS (
  SELECT
    sl.state_code,
    COALESCE(scv.closed_commercial_value, 0) AS commercial_value,
    COALESCE(scc.county_count, 0) AS county_count,
    COALESCE(scase.total_cases, 0) AS case_count,
    COALESCE(sro.responding_orgs, 0) AS responding_orgs,
    COALESCE(shh.households_helped, 0) AS households_helped
  FROM state_list sl
  LEFT JOIN state_commercial_value scv ON sl.state_code = scv.state_code
  LEFT JOIN state_county_counts scc ON sl.state_code = scc.state_code
  LEFT JOIN state_case_counts scase ON sl.state_code = scase.state_code
  LEFT JOIN state_responding_organizations sro ON sl.state_code = sro.state_code
  LEFT JOIN state_households_helped shh ON sl.state_code = shh.state_code
)

-- Final output with state prefix for each CSV and explicit ordering
SELECT 
  "Stat Name",
  "Value"
FROM (
  SELECT 
    ssc.state_code || '_Commercial Value of Volunteer Services' AS "Stat Name",
    CASE 
      WHEN ssc.commercial_value >= 1000000 THEN 
        '$' || ROUND(ssc.commercial_value / 1000000.0, 1) || 'M'
      WHEN ssc.commercial_value >= 1000 THEN 
        '$' || ROUND(ssc.commercial_value / 1000.0, 1) || 'k'
      ELSE 
        '$' || TO_CHAR(ROUND(ssc.commercial_value), 'FM999,999,999')
    END AS "Value",
    1 AS sort_order,
    ssc.state_code AS sort_state
  FROM state_stats_combined ssc

  UNION ALL

  SELECT 
    ssc.state_code || '_Counties (count)' AS "Stat Name",
    TO_CHAR(ssc.county_count, 'FM999,999') AS "Value",
    2 AS sort_order,
    ssc.state_code AS sort_state
  FROM state_stats_combined ssc

  UNION ALL

  SELECT 
    ssc.state_code || '_Cases (count)' AS "Stat Name",
    TO_CHAR(ssc.case_count, 'FM999,999') AS "Value",
    3 AS sort_order,
    ssc.state_code AS sort_state
  FROM state_stats_combined ssc

  UNION ALL

  SELECT 
    ssc.state_code || '_Responding Organizations' AS "Stat Name",
    TO_CHAR(ssc.responding_orgs, 'FM999,999') AS "Value",
    4 AS sort_order,
    ssc.state_code AS sort_state
  FROM state_stats_combined ssc

  UNION ALL

  SELECT 
    ssc.state_code || '_Households Helped' AS "Stat Name",
    TO_CHAR(ssc.households_helped, 'FM999,999') AS "Value",
    5 AS sort_order,
    ssc.state_code AS sort_state
  FROM state_stats_combined ssc
) ordered_results
ORDER BY sort_state, sort_order;