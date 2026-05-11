-- Volunteer Statistics for Magazine Visualizations
-- Generates incident-specific volunteer and response statistics
-- Output: Two-column format with "Stat Name" and "Value"

WITH target_incident AS (
  -- Get target incident details for analysis
  SELECT id, start_at, timezone, incident_type, short_name, name,
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
    MAX(analysis_end)::DATE AS report_end_date,
    (SELECT timezone FROM target_incident LIMIT 1) AS timezone
  FROM incident_analysis_periods
),
temp_worksites AS (
  -- Get worksites for geographic analysis (optimized sampling)
  SELECT DISTINCT aw.id, aw.incident_id, aw.location, aw.county, aw.state,
      CASE 
          WHEN aw.county IS NULL OR aw.state IS NULL THEN true 
          ELSE null 
      END AS select_worksite,
      ROW_NUMBER() OVER(PARTITION BY aw.county, aw.state ORDER BY RANDOM()) AS row_num
  FROM worksite_worksites aw
  INNER JOIN target_incident ti ON aw.incident_id = ti.id
  CROSS JOIN report_period rp
  WHERE aw.invalidated_at IS NULL
    AND DATE(aw.created_at AT TIME ZONE 'UTC' AT TIME ZONE rp.timezone)
          BETWEEN rp.report_start_date AND rp.report_end_date
),
all_worksites AS (
  -- Select sample of worksites for geographic processing
  SELECT ww.id AS worksite_id, ww.incident_id, ww.location, ww.county, ww.state
  FROM worksite_worksites ww
  INNER JOIN temp_worksites tw
      ON tw.id = ww.id
      AND (tw.row_num <= 10000 OR tw.select_worksite IS TRUE)
),
county_locations AS (
  -- Find counties using geographic containment for accurate count
  SELECT DISTINCT ll.name, ll.poly, ll.geom, ll.id AS location_id
  FROM all_worksites AS tws, location_locations AS ll
  WHERE (ST_Contains(ST_Multi(ll.poly), tws.location)
      OR ST_Contains(ST_Multi(ll.geom), tws.location))
      AND ll.type_id IN (
          SELECT id
          FROM location_types AS lt
          WHERE key = 'boundary_political_home_local_division')
      AND ll.created_by = 14
      -- Filter by states if state list is provided
      AND (
        'STATE_LIST_PLACEHOLDER' IS NULL 
        OR RIGHT(ll.name, 2) = ANY(string_to_array(REPLACE('STATE_LIST_PLACEHOLDER', ' ', ''), ','))
      )
),
state_stats AS (
  -- Count unique states affected using county name suffix method
  SELECT COUNT(DISTINCT RIGHT(ll.name, 2)) AS state_count
  FROM county_locations cl, location_locations ll
  WHERE cl.location_id = ll.id
    AND ll.name IS NOT NULL
    AND LENGTH(ll.name) > 2
    AND RIGHT(ll.name, 2) ~ '^[A-Z]{2}$'  -- Ensure last 2 chars are valid state code
),
county_stats AS (
  -- Count unique counties affected using geographic containment method
  SELECT COUNT(DISTINCT cl.location_id) AS county_count
  FROM county_locations cl
),
hotline_stats AS (
  -- Count of hotline calls for target incidents
  SELECT COUNT(DISTINCT pi.session_id) AS call_count
  FROM phone_inbound pi
  WHERE string_to_array('175', ',')::int[] && pi.incident_id -- Support multiple incident IDs
),
case_stats AS (
  -- Total case count within report period
  SELECT COUNT(DISTINCT aw.id) AS total_cases
  FROM worksite_worksites aw
  INNER JOIN target_incident ti ON aw.incident_id = ti.id
  CROSS JOIN report_period rp
  WHERE aw.invalidated_at IS NULL
    AND DATE(aw.created_at AT TIME ZONE 'UTC' AT TIME ZONE rp.timezone)
          BETWEEN rp.report_start_date AND rp.report_end_date
),
organization_stats AS (
  -- Count of organizations participating in response
  SELECT COUNT(DISTINCT ooi.organization_id) AS org_count
  FROM organization_organizations_incidents ooi
  JOIN target_incident ti ON ooi.incident_id = ti.id
  WHERE ooi.approved_at IS NOT NULL
    AND ooi.invalidated_at IS NULL
),
households_stats AS (
  -- Count unique households helped (distinct addresses with completed work)
  SELECT COUNT(DISTINCT aw.id) AS households_helped
  FROM worksite_worksites aw
  INNER JOIN target_incident ti ON aw.incident_id = ti.id
  CROSS JOIN report_period rp
  LEFT JOIN worksite_worksites_work_types_statuses_phases wwwtsp ON aw.id = wwwtsp.worksite_id
  LEFT JOIN worksite_work_statuses wws ON wwwtsp.status_key = wws.status
  WHERE aw.invalidated_at IS NULL
    AND wwwtsp.invalidated_at IS NULL
    AND wws.completed_by_anybody > 0  -- Only completed/closed work
    AND DATE(aw.created_at AT TIME ZONE 'UTC' AT TIME ZONE rp.timezone)
          BETWEEN rp.report_start_date AND rp.report_end_date
)

-- Final output in required format
SELECT 'States Count' AS "Stat Name",
       CASE WHEN ss.state_count >= 1000 
            THEN TO_CHAR(ss.state_count, 'FM999,999,999')
            ELSE ss.state_count::text 
       END AS "Value"
FROM state_stats ss

UNION ALL

SELECT 'Counties Count' AS "Stat Name",
       CASE WHEN cos.county_count >= 1000 
            THEN TO_CHAR(cos.county_count, 'FM999,999,999')
            ELSE cos.county_count::text 
       END AS "Value"
FROM county_stats cos

UNION ALL

SELECT 'Hotline Calls Count' AS "Stat Name",
       CASE WHEN hs.call_count >= 1000 
            THEN TO_CHAR(hs.call_count, 'FM999,999,999')
            ELSE hs.call_count::text 
       END AS "Value"
FROM hotline_stats hs

UNION ALL

SELECT 'Cases Count' AS "Stat Name",
       TO_CHAR(cs.total_cases, 'FM999,999,999') AS "Value"
FROM case_stats cs

UNION ALL

SELECT 'Responding Organizations Count' AS "Stat Name",
       CASE WHEN os.org_count >= 1000 
            THEN TO_CHAR(os.org_count, 'FM999,999,999')
            ELSE os.org_count::text 
       END AS "Value"
FROM organization_stats os

UNION ALL

SELECT 'Households Helped' AS "Stat Name",
       TO_CHAR(hs.households_helped, 'FM999,999,999') AS "Value"
FROM households_stats hs;