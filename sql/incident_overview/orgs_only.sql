-- Organizations timeline data for 2_orgs_timeline visualization
-- Extracted from incident_summary_orgs_calls.sql - Organizations part only

WITH years AS (
    SELECT DISTINCT EXTRACT(YEAR FROM approved_at)::INTEGER AS year 
    FROM organization_organizations_incidents 
    WHERE approved_at IS NOT NULL
),
deploy_counts AS (
    SELECT EXTRACT(YEAR FROM approved_at)::INTEGER AS year, 
        COUNT(id) AS deployment_count
    FROM organization_organizations_incidents AS ooi
    WHERE ooi.incident_id IN (
        SELECT id FROM incident_incidents 
        WHERE (
          CASE
            WHEN incident_type = 'tornado' THEN 'Tornado'
            WHEN incident_type IN ('hurricane', 'tropical_storm') THEN 'Hurricanes & Tropical Storms'
            WHEN incident_type IN ('flood_tornado_wind', 'wind', 'hail', 'flood_tstorm') THEN 'Severe Weather'
            WHEN incident_type IN ('snow', 'ice_storm') THEN 'Snow & Ice'
            WHEN incident_type = 'fire' THEN 'Fire'
            WHEN incident_type = 'rebuild' THEN 'Rebuild'
            WHEN incident_type IN ('earthquake', 'volcano') THEN 'Earthquake & Volcano'
            WHEN incident_type IN ('contaminated_water', 'virus') THEN 'Other'
            WHEN incident_type IN ('flood', 'mudslide') THEN 'Flood'
            ELSE 'Unknown'
          END
        ) = 'INCIDENT_TYPE_PLACEHOLDER'
        AND invalidated_at IS NULL
    )
    AND ooi.approved_at IS NOT NULL
    AND ooi.invalidated_at IS NULL
    GROUP BY 1
)
SELECT 
    y.year::INTEGER, 
    COALESCE(ic.deployment_count, 0) AS organizations
FROM years y
LEFT JOIN deploy_counts ic 
ON y.year = ic.year
ORDER BY y.year;