-- Front Cover Statistics
-- Generates comprehensive statistics for magazine front cover
-- Output: Two-column format with "Stat Name" and "Value"

WITH target_incident AS (
  -- Selects the target incidents and their configured start dates in their local timezones
  -- Support for multiple incident IDs (comma-separated): e.g., '175' or '175,172,180'
  SELECT
    id,
    start_at,
    timezone,
    incident_type,
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
incident_type_stats AS (
  -- Count of incidents of the input type that started before the latest target incident
  -- If no incident_type specified, use the type from target incidents
  SELECT COUNT(*) AS incident_count
  FROM incident_incidents ii
  CROSS JOIN target_incident ti
  WHERE (
    CASE
      WHEN ii.incident_type = 'tornado' THEN 'Tornado'
      WHEN ii.incident_type IN ('hurricane', 'tropical_storm') THEN 'Hurricanes & Tropical Storms'
      WHEN ii.incident_type IN ('flood_tornado_wind', 'wind', 'hail', 'flood_tstorm') THEN 'Severe Weather'
      WHEN ii.incident_type IN ('snow', 'ice_storm') THEN 'Snow & Ice'
      WHEN ii.incident_type = 'fire' THEN 'Fire'
      WHEN ii.incident_type = 'rebuild' THEN 'Rebuild'
      WHEN ii.incident_type IN ('earthquake', 'volcano') THEN 'Earthquake & Volcano'
      WHEN ii.incident_type IN ('contaminated_water', 'virus') THEN 'Other'
      WHEN ii.incident_type IN ('flood', 'mudslide') THEN 'Flood'
      ELSE 'Unknown'
    END
  ) = COALESCE('INCIDENT_TYPE_PLACEHOLDER', ti.incident_type)
    AND ii.start_at <= (SELECT MAX(start_at) FROM target_incident)
),
hotline_stats AS (
  -- Count of hotline calls for target incidents
  SELECT COUNT(DISTINCT pi.session_id) AS call_count
  FROM phone_inbound pi
  WHERE string_to_array('175', ',')::int[] && pi.incident_id -- Support multiple incident IDs
),
organization_stats AS (
  -- Count of organizations participating in CCU response (redeploy total)
  SELECT COUNT(DISTINCT ooi.organization_id) AS org_count
  FROM organization_organizations_incidents ooi
  JOIN target_incident ti ON ooi.incident_id = ti.id
  WHERE ooi.approved_at IS NOT NULL
    AND ooi.invalidated_at IS NULL
),
case_stats AS (
  -- Total case count and closed commercial value within report period
  SELECT 
    COUNT(DISTINCT aw.id) AS total_cases,
    COALESCE(SUM(wwt.commercial_value * wws.completed_by_anybody), 0) AS closed_value
  FROM worksite_worksites aw
  INNER JOIN target_incident ti ON aw.incident_id = ti.id
  CROSS JOIN report_period rp
  LEFT JOIN worksite_worksites_work_types_statuses_phases wwwtsp ON aw.id = wwwtsp.worksite_id
  LEFT JOIN worksite_work_statuses wws ON wwwtsp.status_key = wws.status
  LEFT JOIN worksite_work_types wwt ON wwwtsp.work_type_key = wwt.key
  WHERE aw.invalidated_at IS NULL
    AND wwwtsp.invalidated_at IS NULL
    AND DATE(aw.created_at AT TIME ZONE 'UTC' AT TIME ZONE ti.timezone)
          BETWEEN rp.report_start_date AND rp.report_end_date
),
temp_worksites AS (
  -- Get worksites for county geographic analysis (similar to county_summary_new_cases_stats.sql)
  SELECT DISTINCT aw.id, aw.incident_id, aw.location, aw.county, aw.state,
      CASE 
          WHEN aw.county IS NULL OR aw.state IS NULL THEN true 
          ELSE null 
      END AS select_worksite,
      ROW_NUMBER() OVER(PARTITION BY aw.county, aw.state ORDER BY RANDOM()) AS row_num
  FROM worksite_worksites aw
  INNER JOIN target_incident ti ON aw.incident_id = ti.id
  CROSS JOIN report_period rp
  WHERE aw.incident_id = ANY(string_to_array('175', ',')::int[]) -- Will be replaced by orchestrator
      AND aw.invalidated_at IS NULL
      AND DATE(aw.created_at AT TIME ZONE 'UTC' AT TIME ZONE ti.timezone)
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
  -- Find counties using geographic containment
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
county_stats AS (
  -- Count distinct counties using geographic containment method
  SELECT COUNT(DISTINCT cl.location_id) AS county_count
  FROM county_locations cl
),
state_stats AS (
  -- List of states - use input parameter if provided, otherwise show affected states from data
  SELECT 
    COALESCE('STATE_LIST_PLACEHOLDER', STRING_AGG(DISTINCT aw.state, ', ' ORDER BY aw.state)) AS affected_states
  FROM worksite_worksites aw
  INNER JOIN target_incident ti ON aw.incident_id = ti.id
  CROSS JOIN report_period rp
  WHERE aw.invalidated_at IS NULL
    AND aw.state IS NOT NULL
    AND aw.state != ''
    AND DATE(aw.created_at AT TIME ZONE 'UTC' AT TIME ZONE ti.timezone)
          BETWEEN rp.report_start_date AND rp.report_end_date
),
work_type_stats AS (
  -- Work type percentages (excluding certain types, state agnostic for front page)
  SELECT 
    wwwtsp.work_type_key,
    COUNT(*) as work_type_count,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 0) as percentage
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
  ORDER BY work_type_count DESC
),
work_type_percentages AS (
  -- Format work type percentages as single space-separated string
  SELECT STRING_AGG(
    REPLACE(INITCAP(REPLACE(work_type_key, '_', ' ')), 'Mucb', 'Muck') || ': ' || percentage || '%',
    ' '
    ORDER BY work_type_count DESC
  ) AS work_type_breakdown
  FROM work_type_stats
)

-- Final output in required format
SELECT 'Number of incidents of the current type' AS "Stat Name", 
       CASE WHEN its.incident_count >= 1000 
            THEN TO_CHAR(its.incident_count, 'FM999,999,999')
            ELSE its.incident_count::text 
       END AS "Value"
FROM incident_type_stats its

UNION ALL

SELECT 'Number of hotline calls' AS "Stat Name",
       CASE WHEN hs.call_count >= 1000 
            THEN TO_CHAR(hs.call_count, 'FM999,999,999')
            ELSE hs.call_count::text 
       END AS "Value"
FROM hotline_stats hs

UNION ALL

SELECT 'Number of organizations participating in the CCU response (redeploy total)' AS "Stat Name",
       CASE WHEN os.org_count >= 1000 
            THEN TO_CHAR(os.org_count, 'FM999,999,999')
            ELSE os.org_count::text 
       END AS "Value"
FROM organization_stats os

UNION ALL

SELECT 'Total case count' AS "Stat Name",
       TO_CHAR(cs.total_cases, 'FM999,999,999') AS "Value"
FROM case_stats cs

UNION ALL

SELECT 'Total value of volunteer services' AS "Stat Name",
       '$' || TO_CHAR(cs.closed_value, 'FM999,999,999') AS "Value"
FROM case_stats cs

UNION ALL

SELECT 'Number of counties affected' AS "Stat Name",
       CASE WHEN cos.county_count >= 1000 
            THEN TO_CHAR(cos.county_count, 'FM999,999,999')
            ELSE cos.county_count::text 
       END AS "Value"
FROM county_stats cos

UNION ALL

SELECT 'List of all affected states' AS "Stat Name",
       ss.affected_states AS "Value"
FROM state_stats ss

UNION ALL

SELECT 'Percentages of each work type requested' AS "Stat Name",
       wtp.work_type_breakdown AS "Value"
FROM work_type_percentages wtp;