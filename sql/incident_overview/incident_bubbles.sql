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
  -- Get the first target incident for multi-incident grouping
  SELECT name, short_name, incident_type, start_at
  FROM incident_incidents
  WHERE id = ANY(string_to_array('175', ',')::int[])
  ORDER BY start_at ASC
  LIMIT 1
),
worksite_values AS (
  -- First, calculate closed and total value for each work type on each worksite
  SELECT
    aw.incident_id,
    aw.id AS worksite_id,
    COALESCE(wwt.commercial_value * wws.completed_by_anybody, 0) AS closed_value,
    COALESCE(wwt.commercial_value, 0) AS total_value
  FROM worksite_worksites aw
  LEFT JOIN worksite_worksites_work_types_statuses_phases wwwtsp ON aw.id = wwwtsp.worksite_id
  LEFT JOIN worksite_work_statuses wws ON wwwtsp.status_key = wws.status
  LEFT JOIN worksite_work_types wwt ON wwwtsp.work_type_key = wwt.key
  WHERE wwwtsp.invalidated_at IS NULL
    AND aw.invalidated_at IS NULL
),
worksite_ratios AS (
  -- Second, aggregate by worksite to get a completion ratio for each one
  SELECT
    incident_id,
    worksite_id,
    -- This ratio represents the "fractional completion" of a single worksite
    SUM(closed_value) / NULLIF(SUM(total_value), 0) AS worksite_closed_ratio
  FROM worksite_values
  GROUP BY incident_id, worksite_id
),
incident_grouping AS (
  -- Create a grouping key that treats target incidents as one group
  SELECT
    ii.id,
    CASE WHEN ii.id IN (SELECT id FROM target_incident_ids) THEN 'TARGET_GROUP' ELSE ii.id::text END AS group_key,
    ii.name,
    ii.short_name,
    ii.incident_type,
    ii.start_at
  FROM incident_incidents ii
),
agg AS (
  -- Finally, aggregate by grouping key
  SELECT
    CASE
      WHEN ig.group_key = 'TARGET_GROUP' THEN (SELECT name FROM first_target_incident)
      ELSE MAX(ig.name)
    END AS incident_name,
    CASE
      WHEN ig.group_key = 'TARGET_GROUP' THEN (SELECT short_name FROM first_target_incident)
      ELSE MAX(ig.short_name)
    END AS incident_short_name,
    CASE
      WHEN ig.group_key = 'TARGET_GROUP' THEN
        CASE
          WHEN (SELECT incident_type FROM first_target_incident) = 'tornado' THEN 'Tornado'
          WHEN (SELECT incident_type FROM first_target_incident) IN ('hurricane', 'tropical_storm') THEN 'Hurricanes & Tropical Storms'
          WHEN (SELECT incident_type FROM first_target_incident) IN ('flood_tornado_wind', 'wind', 'hail', 'flood_tstorm') THEN 'Severe Weather'
          WHEN (SELECT incident_type FROM first_target_incident) IN ('snow', 'ice_storm') THEN 'Snow & Ice'
          WHEN (SELECT incident_type FROM first_target_incident) = 'fire' THEN 'Fire'
          WHEN (SELECT incident_type FROM first_target_incident) = 'rebuild' THEN 'Rebuild'
          WHEN (SELECT incident_type FROM first_target_incident) IN ('earthquake', 'volcano') THEN 'Earthquake & Volcano'
          WHEN (SELECT incident_type FROM first_target_incident) IN ('contaminated_water', 'virus') THEN 'Other'
          WHEN (SELECT incident_type FROM first_target_incident) IN ('flood', 'mudslide') THEN 'Flood'
          ELSE 'Unknown'
        END
      ELSE
        CASE
          WHEN MAX(ig.incident_type) = 'tornado' THEN 'Tornado'
          WHEN MAX(ig.incident_type) IN ('hurricane', 'tropical_storm') THEN 'Hurricanes & Tropical Storms'
          WHEN MAX(ig.incident_type) IN ('flood_tornado_wind', 'wind', 'hail', 'flood_tstorm') THEN 'Severe Weather'
          WHEN MAX(ig.incident_type) IN ('snow', 'ice_storm') THEN 'Snow & Ice'
          WHEN MAX(ig.incident_type) = 'fire' THEN 'Fire'
          WHEN MAX(ig.incident_type) = 'rebuild' THEN 'Rebuild'
          WHEN MAX(ig.incident_type) IN ('earthquake', 'volcano') THEN 'Earthquake & Volcano'
          WHEN MAX(ig.incident_type) IN ('contaminated_water', 'virus') THEN 'Other'
          WHEN MAX(ig.incident_type) IN ('flood', 'mudslide') THEN 'Flood'
          ELSE 'Unknown'
        END
    END AS incident_type,
    CASE
      WHEN ig.group_key = 'TARGET_GROUP' THEN DATE((SELECT start_at FROM first_target_incident))
      ELSE DATE(MAX(ig.start_at))
    END AS start_date,
    CASE
      WHEN ig.group_key = 'TARGET_GROUP' THEN EXTRACT(YEAR FROM (SELECT start_at FROM first_target_incident))::INTEGER
      ELSE EXTRACT(YEAR FROM MAX(ig.start_at))::INTEGER
    END AS start_year,
    -- New closed_cases is the sum of each worksite's fractional completion
    SUM(wr.worksite_closed_ratio) AS closed_cases,
    -- Total cases is the count of worksites in the incident
    COUNT(wr.worksite_id) AS total_cases,
    -- pct_closed is the average completion across all worksites
    AVG(wr.worksite_closed_ratio) AS pct_closed
  FROM worksite_ratios wr
  INNER JOIN incident_grouping ig ON ig.id = wr.incident_id
  GROUP BY ig.group_key
)
SELECT
  a.incident_name,
  a.incident_short_name,
  a.incident_type,
  a.total_cases,
  a.closed_cases,
  -- The formatting of the percentage remains the same
  CONCAT(ROUND(a.pct_closed * 100, 2), '%') AS pct_closed,
  a.start_date,
  a.start_year AS x_axis,
  RANK() OVER (PARTITION BY a.incident_type, a.start_year ORDER BY a.start_date) AS incident_order
FROM agg a
WHERE a.incident_type = 'INCIDENT_TYPE_PLACEHOLDER';