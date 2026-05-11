-- History Insights for Magazine Visualizations
-- Generates contextual insights including incident ranking and type-based captions
-- Output: Two-column format with "Insights" and "Value"

WITH target_incident AS (
  -- Get target incident details for analysis
  SELECT id, start_at, timezone, incident_type, short_name, name
  FROM incident_incidents
  WHERE id = ANY(string_to_array('175', ',')::int[])
  ORDER BY start_at ASC
  LIMIT 1  -- Use earliest target incident
),
target_incident_type AS (
  -- Get the incident type to analyze (from input parameter or target incidents)
  SELECT COALESCE('INCIDENT_TYPE_PLACEHOLDER', 
                  (SELECT incident_type FROM target_incident)) AS incident_type
),
historical_incidents AS (
  -- All incidents of the specified type that started before or at the target incident
  SELECT ii.id, ii.start_at, ii.timezone, ii.incident_type, ii.short_name, ii.name
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
    AND ii.start_at <= ti.start_at  -- Include incidents up to and including target incident
),
incident_case_counts AS (
  -- Calculate case counts for all historical incidents for ranking
  SELECT 
    hi.id,
    hi.short_name,
    hi.name,
    COUNT(DISTINCT aw.id) AS case_count
  FROM historical_incidents hi
  LEFT JOIN worksite_worksites aw ON hi.id = aw.incident_id
  WHERE aw.invalidated_at IS NULL OR aw.id IS NULL
  GROUP BY hi.id, hi.short_name, hi.name
),
incident_ranking AS (
  -- Rank incidents by case count (largest to smallest)
  SELECT 
    id,
    short_name,
    name,
    case_count,
    RANK() OVER (ORDER BY case_count DESC) AS rank_position,
    COUNT(*) OVER () AS total_incidents
  FROM incident_case_counts
  WHERE case_count > 0
),
target_incident_rank AS (
  -- Get the rank of our target incident
  SELECT 
    ir.rank_position,
    ir.total_incidents,
    ir.short_name,
    ir.name,
    ir.case_count,
    ti.incident_type
  FROM incident_ranking ir
  INNER JOIN target_incident ti ON ir.id = ti.id
),
ordinal_suffix AS (
  -- Generate ordinal suffixes (1st, 2nd, 3rd, 4th, etc.)
  SELECT 
    rank_position,
    total_incidents,
    short_name,
    name,
    case_count,
    incident_type,
    CASE 
      WHEN rank_position % 100 BETWEEN 11 AND 13 THEN rank_position::text || 'th'
      WHEN rank_position % 10 = 1 THEN rank_position::text || 'st'
      WHEN rank_position % 10 = 2 THEN rank_position::text || 'nd' 
      WHEN rank_position % 10 = 3 THEN rank_position::text || 'rd'
      ELSE rank_position::text || 'th'
    END AS ordinal_rank
  FROM target_incident_rank
),
incident_type_formatted AS (
  -- Format incident type for captions (capitalize first letter, handle plurals)
  SELECT 
    *,
    CASE 
      WHEN incident_type = 'Tornado' THEN 'Tornado'
      WHEN incident_type = 'Hurricanes & Tropical Storms' THEN 'Hurricane'
      WHEN incident_type = 'Severe Weather' THEN 'Severe Weather Event'
      WHEN incident_type = 'Snow & Ice' THEN 'Snow & Ice Event'
      WHEN incident_type = 'Fire' THEN 'Fire'
      WHEN incident_type = 'Flood' THEN 'Flood'
      WHEN incident_type = 'Earthquake & Volcano' THEN 'Earthquake & Volcano Event'
      WHEN incident_type = 'Other' THEN 'Other Event'
      WHEN incident_type = 'Rebuild' THEN 'Rebuild'
      ELSE incident_type
    END AS incident_type_singular,
    CASE 
      WHEN incident_type = 'Tornado' THEN 'Tornados'
      WHEN incident_type = 'Hurricanes & Tropical Storms' THEN 'Hurricanes & Tropical Storms'
      WHEN incident_type = 'Severe Weather' THEN 'Severe Weather Events'
      WHEN incident_type = 'Snow & Ice' THEN 'Snow & Ice Events'
      WHEN incident_type = 'Fire' THEN 'Fires'
      WHEN incident_type = 'Flood' THEN 'Floods'
      WHEN incident_type = 'Earthquake & Volcano' THEN 'Earthquake & Volcano Events'
      WHEN incident_type = 'Other' THEN 'Other Events'
      WHEN incident_type = 'Rebuild' THEN 'Rebuilds'
      ELSE incident_type || 's'
    END AS incident_type_plural
  FROM ordinal_suffix
)

-- Final output in required format
SELECT 'Bar Graph: Incident Comparison' AS "Insights",
       'The ' || 
       COALESCE(itf.name, itf.short_name) || 
       ' was the ' || 
       itf.ordinal_rank || 
       ' largest response in terms of the number of cases created.' AS "Value"
FROM incident_type_formatted itf

UNION ALL

SELECT 'Bar & Area Graph: Organizational Engagement & Calls' AS "Insights",
       'Each bar represents the number of organizations engaging in relief efforts by year across ' || 
       itf.incident_type_plural || 
       '. The background area plot indicates the number of inbound phone calls across the same timeframe.' AS "Value"
FROM incident_type_formatted itf;