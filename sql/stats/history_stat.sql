-- Historical Statistics by Incident Type
-- Generates comprehensive historical statistics for all incidents of the specified type
-- Output: Two-column format with "Stat Name" and "Value"

WITH target_incident AS (
  -- Get target incident details for date filtering
  SELECT id, start_at, timezone, incident_type
  FROM incident_incidents
  WHERE id = ANY(string_to_array('175', ',')::int[])
  ORDER BY start_at ASC
  LIMIT 1  -- Use earliest target incident for date cutoff
),
target_incident_type AS (
  -- Get the incident type to analyze (from input parameter or target incidents)
  SELECT COALESCE('INCIDENT_TYPE_PLACEHOLDER', 
                  (SELECT incident_type FROM target_incident)) AS incident_type
),
historical_incidents AS (
  -- All incidents of the specified type that started before the target incident
  SELECT ii.id, ii.start_at, ii.timezone, ii.incident_type, ii.short_name
  FROM incident_incidents ii
  CROSS JOIN target_incident_type tit
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
  ) = tit.incident_type
    AND ii.invalidated_at IS NULL
    AND ii.start_at <= ti.start_at  -- Only include incidents that started before target incident
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
  INNER JOIN historical_incidents hi ON aw.incident_id = hi.id
  WHERE aw.invalidated_at IS NULL
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
),
historical_states AS (
  -- Count unique states affected by incidents of this type (using county name suffix method)
  SELECT COUNT(DISTINCT RIGHT(ll.name, 2)) AS state_count
  FROM county_locations cl, location_locations ll
  WHERE cl.location_id = ll.id
    AND ll.name IS NOT NULL
    AND LENGTH(ll.name) > 2
    AND RIGHT(ll.name, 2) ~ '^[A-Z]{2}$'  -- Ensure last 2 chars are valid state code
),
historical_counties AS (
  -- Count unique counties affected using geographic containment
  SELECT COUNT(DISTINCT cl.location_id) AS county_count
  FROM county_locations cl
),
historical_organizations AS (
  -- Count unique organizations that have responded to incidents of this type
  SELECT COUNT(DISTINCT ooi.organization_id) AS org_count
  FROM organization_organizations_incidents ooi
  INNER JOIN historical_incidents hi ON ooi.incident_id = hi.id
  WHERE ooi.approved_at IS NOT NULL
    AND ooi.invalidated_at IS NULL
),
historical_cases AS (
  -- Count total cases across all incidents of this type
  SELECT COUNT(DISTINCT aw.id) AS case_count
  FROM worksite_worksites aw
  INNER JOIN historical_incidents hi ON aw.incident_id = hi.id
  WHERE aw.invalidated_at IS NULL
),
historical_calls AS (
  -- Count total hotline calls across all incidents of this type
  SELECT COUNT(DISTINCT pi.session_id) AS call_count
  FROM phone_inbound pi
  INNER JOIN historical_incidents hi ON hi.id = ANY(pi.incident_id)
),
historical_commercial_value AS (
  -- Calculate CLOSED commercial value across all incidents of this type
  SELECT COALESCE(SUM(wwt.commercial_value * wws.completed_by_anybody), 0) AS total_value
  FROM worksite_worksites aw
  INNER JOIN historical_incidents hi ON aw.incident_id = hi.id
  LEFT JOIN worksite_worksites_work_types_statuses_phases wwwtsp ON aw.id = wwwtsp.worksite_id
  LEFT JOIN worksite_work_types wwt ON wwwtsp.work_type_key = wwt.key
  LEFT JOIN worksite_work_statuses wws ON wwwtsp.status_key = wws.status
  WHERE aw.invalidated_at IS NULL
    AND wwwtsp.invalidated_at IS NULL
    AND wwt.commercial_value IS NOT NULL
    AND wwt.commercial_value > 0
    AND wws.completed_by_anybody > 0  -- Only completed/closed work
),
incident_count AS (
  -- Count total number of incidents of this type
  SELECT COUNT(DISTINCT id) AS incident_count
  FROM historical_incidents
)

-- Final output in required format
SELECT 'Number of incidents of this type' AS "Stat Name",
       CASE WHEN ic.incident_count >= 1000 
            THEN TO_CHAR(ic.incident_count, 'FM999,999,999')
            ELSE ic.incident_count::text 
       END AS "Value"
FROM incident_count ic

UNION ALL

SELECT 'Number of states affected by incidents of this type' AS "Stat Name",
       CASE WHEN hs.state_count >= 1000 
            THEN TO_CHAR(hs.state_count, 'FM999,999,999')
            ELSE hs.state_count::text 
       END AS "Value"
FROM historical_states hs

UNION ALL

SELECT 'Number of counties affected by incidents of this type' AS "Stat Name",
       CASE WHEN hc.county_count >= 1000 
            THEN TO_CHAR(hc.county_count, 'FM999,999,999')
            ELSE hc.county_count::text 
       END AS "Value"
FROM historical_counties hc

UNION ALL

SELECT 'Responding Organizations to incidents of this type' AS "Stat Name",
       CASE WHEN ho.org_count >= 1000 
            THEN TO_CHAR(ho.org_count, 'FM999,999,999')
            ELSE ho.org_count::text 
       END AS "Value"
FROM historical_organizations ho

UNION ALL

SELECT 'Total number of cases in incidents of this type' AS "Stat Name",
       TO_CHAR(hcs.case_count, 'FM999,999,999') AS "Value"
FROM historical_cases hcs

UNION ALL

SELECT 'Total number of calls in incidents of this type' AS "Stat Name",
       TO_CHAR(hcl.call_count, 'FM999,999,999') AS "Value"
FROM historical_calls hcl

UNION ALL

SELECT 'Total commercial value of volunteer services' AS "Stat Name",
       CASE 
         WHEN hcv.total_value IS NULL OR hcv.total_value = 0 THEN '$0'
         ELSE '$' || REPLACE(TO_CHAR(hcv.total_value::bigint, 'FM999G999G999G999G999'), 'G', ',')
       END AS "Value"
FROM historical_commercial_value hcv;