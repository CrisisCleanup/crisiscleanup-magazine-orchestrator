-- Phone calls timeline data for 2_calls_timeline visualization
-- Extracted from incident_summary_orgs_calls.sql - Calls part only
-- Includes focus incident date filtering and special rounding logic

WITH target_incident AS (
  -- Get target incident details for date filtering
  SELECT id, start_at, timezone, incident_type
  FROM incident_incidents
  WHERE id = ANY(string_to_array('175', ',')::int[])
  ORDER BY start_at ASC
  LIMIT 1  -- Use earliest target incident for date cutoff
),
years AS (
    -- Get a distinct list of years, but only from calls linked to incidents of the specified type
    -- that started before or at the target incident
    SELECT DISTINCT EXTRACT(YEAR FROM pi.created_at) AS year 
    FROM phone_inbound pi
    INNER JOIN incident_incidents ii ON ii.id = ANY(pi.incident_id)
    CROSS JOIN target_incident ti
    WHERE pi.created_at IS NOT NULL
    AND ii.start_at <= ti.start_at  -- Only include incidents that started before or at the target incident
    AND ii.invalidated_at IS NULL
    AND (
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
    ) = 'INCIDENT_TYPE_PLACEHOLDER'
),
phone_call_counts AS (
    -- Count distinct phone calls per year, but only for calls linked to incidents of the specified type
    -- that started before or at the target incident
    SELECT 
        EXTRACT(YEAR FROM pi.created_at) AS year,
        COUNT(DISTINCT pi.session_id) AS phone_calls_raw
    FROM phone_inbound pi
    INNER JOIN incident_incidents ii ON ii.id = ANY(pi.incident_id)
    CROSS JOIN target_incident ti
    WHERE pi.created_at IS NOT NULL
    AND ii.start_at <= ti.start_at  -- Only include incidents that started before or at the target incident
    AND ii.invalidated_at IS NULL
    AND (
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
    ) = 'INCIDENT_TYPE_PLACEHOLDER'
    GROUP BY 1
)
SELECT 
    y.year::INTEGER, 
    -- Special rounding: convert to thousands and round to 1 decimal place
    -- Examples: 8,072 -> 8.1, 912 -> 0.9
    ROUND(COALESCE(pcc.phone_calls_raw, 0) / 1000.0, 1) AS "phone calls"
FROM years y
LEFT JOIN phone_call_counts pcc 
ON y.year = pcc.year
ORDER BY y.year;