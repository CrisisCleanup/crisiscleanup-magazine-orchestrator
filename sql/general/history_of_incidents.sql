WITH target_incident AS (
  -- Get target incident details for date filtering
  SELECT id, start_at, timezone, incident_type
  FROM incident_incidents
  WHERE id = ANY(string_to_array('175', ',')::int[])
  ORDER BY start_at ASC
  LIMIT 1  -- Use earliest target incident for date cutoff
),
target_incident_ids AS (
  -- Get all target incident IDs for grouping
  SELECT id FROM incident_incidents
  WHERE id = ANY(string_to_array('175', ',')::int[])
),
first_target_incident AS (
  -- Get the first target incident name for multi-incident grouping
  SELECT short_name, start_at
  FROM incident_incidents
  WHERE id = ANY(string_to_array('175', ',')::int[])
  ORDER BY start_at ASC
  LIMIT 1
),
incident_grouping AS (
  -- Create a grouping key that treats target incidents as one group
  SELECT
    ii.id,
    CASE WHEN ii.id IN (SELECT id FROM target_incident_ids) THEN 'TARGET_GROUP' ELSE ii.id::text END AS group_key,
    ii.short_name,
    ii.incident_type,
    ii.start_at
  FROM incident_incidents ii
  WHERE ii.invalidated_at IS NULL
)
SELECT
  CASE
    WHEN ig.group_key = 'TARGET_GROUP' THEN
      CONCAT((SELECT short_name FROM first_target_incident), ' ',
             LEFT(CAST((SELECT start_at FROM first_target_incident) AS varchar), 4))
    ELSE CONCAT(MAX(ig.short_name), ' ', LEFT(CAST(MAX(ig.start_at) AS varchar), 4))
  END AS incident_short_name,
  COUNT(ww.id) AS total_cases
FROM worksite_worksites AS ww
INNER JOIN incident_grouping ig ON ww.incident_id = ig.id
WHERE ww.invalidated_at IS NULL
  AND (
    CASE
      WHEN ig.incident_type = 'tornado' THEN 'Tornado'
      WHEN ig.incident_type IN ('hurricane', 'tropical_storm') THEN 'Hurricanes & Tropical Storms'
      WHEN ig.incident_type IN ('flood_tornado_wind', 'wind', 'hail', 'flood_tstorm') THEN 'Severe Weather'
      WHEN ig.incident_type IN ('snow', 'ice_storm') THEN 'Snow & Ice'
      WHEN ig.incident_type = 'fire' THEN 'Fire'
      WHEN ig.incident_type = 'rebuild' THEN 'Rebuild'
      WHEN ig.incident_type IN ('earthquake', 'volcano') THEN 'Earthquake & Volcano'
      WHEN ig.incident_type IN ('contaminated_water', 'virus') THEN 'Other'
      WHEN ig.incident_type IN ('flood', 'mudslide') THEN 'Flood'
      ELSE 'Unknown'
    END
  ) = 'INCIDENT_TYPE_PLACEHOLDER'
GROUP BY ig.group_key
ORDER BY total_cases ASC;