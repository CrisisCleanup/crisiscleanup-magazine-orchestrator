-- Proportional Area Chart: Geographic Case Distribution
-- Output: Three-column format with "area", "total_cases", "percentage_closed"
-- Uses pre-computed geographic fields from omni table (no ST_Contains needed)
-- Includes both counties AND cities (for independent cities like St. Louis City)

WITH target_incident AS (
  -- Standard multi-incident target incident selection
  SELECT
    id,
    name,
    start_at,
    timezone
  FROM incident_incidents
  WHERE id = ANY(string_to_array('175', ',')::int[])
),
worksites_in_period AS (
  -- Find all worksites that appear in the analysis period with their geographic info
  SELECT DISTINCT ON (worksite_id)
    worksite_id,
    home_local_division_name AS county_name,
    home_city_name,
    home_postal_code_name,
    RIGHT(COALESCE(home_local_division_name, home_city_name), 2) AS home_state
  FROM r.cases_new_claimed_closed_omni_mag
  WHERE incident_id = ANY(string_to_array('175', ',')::int[])
    AND is_within_analysis = true
    -- Filter by state list
    AND RIGHT(COALESCE(home_local_division_name, home_city_name), 2) = ANY(string_to_array(REPLACE('STATE_LIST_PLACEHOLDER', ' ', ''), ','))
    AND invalidated_at IS NULL
  ORDER BY worksite_id, the_date ASC
),
end_of_period_snapshot AS (
  -- Get the final snapshot for each worksite using DISTINCT ON
  SELECT DISTINCT ON (omni.worksite_id, omni.work_type_key)
    omni.worksite_id,
    wp.county_name,
    wp.home_city_name,
    wp.home_postal_code_name,
    wp.home_state,
    omni.work_type_key,
    omni.work_type_value,
    omni.percent_closed_hash
  FROM r.cases_new_claimed_closed_omni_mag omni
  INNER JOIN worksites_in_period wp ON omni.worksite_id = wp.worksite_id
  WHERE omni.incident_id = ANY(string_to_array('175', ',')::int[])
    AND omni.is_within_analysis = true
    AND omni.work_type_key NOT IN ('mold_remediation', 'rebuild', 'heating', 'shopping', 'report')
    AND omni.invalidated_at IS NULL  -- Exclude invalidated work types
  ORDER BY omni.worksite_id, omni.work_type_key, omni.the_date DESC, omni.created_at DESC
),
worksite_aggregates AS (
  -- Aggregate work types to worksite level
  SELECT
    worksite_id,
    county_name,
    home_city_name,
    home_postal_code_name,
    home_state,
    -- Total value and closed value per worksite
    SUM(work_type_value) AS total_value,
    SUM(work_type_value * percent_closed_hash) AS closed_value
  FROM end_of_period_snapshot
  GROUP BY worksite_id, county_name, home_city_name, home_postal_code_name, home_state
),
area_count_check AS (
  -- Count total geographic areas (counties + cities) to determine granularity
  SELECT
    COUNT(DISTINCT COALESCE(county_name, home_city_name)) AS total_areas
  FROM worksite_aggregates
  WHERE COALESCE(county_name, home_city_name) IS NOT NULL
),
area_aggregates AS (
  -- Aggregate by county/city or postal code depending on area count
  SELECT
    CASE
      WHEN acc.total_areas > 3 THEN
        -- County/city mode
        CASE
          WHEN wa.county_name IS NULL AND wa.home_city_name IS NOT NULL THEN
            -- Independent city: add " City" suffix
            REGEXP_REPLACE(wa.home_city_name, ', [A-Z]{2}$', '') || ' City'
          ELSE
            -- County: remove " County" suffix and state code
            REGEXP_REPLACE(REGEXP_REPLACE(wa.county_name, ', [A-Z]{2}$', ''), ' County$', '')
        END
      ELSE
        -- Postal code mode
        'Zip Code: ' || wa.home_postal_code_name
    END AS area_name,
    COUNT(wa.worksite_id) AS total_cases,
    SUM(wa.closed_value / NULLIF(wa.total_value, 0)) AS closed_cases
  FROM worksite_aggregates wa
  CROSS JOIN area_count_check acc
  WHERE (
    (acc.total_areas > 3 AND COALESCE(wa.county_name, wa.home_city_name) IS NOT NULL) OR
    (acc.total_areas <= 3 AND wa.home_postal_code_name IS NOT NULL)
  )
  GROUP BY area_name
),
area_stats_with_percentage AS (
  SELECT
    area_name,
    total_cases::integer,
    ROUND(
      CASE
        WHEN total_cases > 0 THEN closed_cases / total_cases::numeric
        ELSE 0
      END, 2
    ) AS percentage_closed,  -- Decimal format (e.g., 0.33 instead of 33%)
    ROW_NUMBER() OVER (ORDER BY total_cases DESC) as rank
  FROM area_aggregates
  WHERE area_name IS NOT NULL
),
top_areas AS (
  SELECT
    area_name,
    total_cases,
    percentage_closed,
    0 AS sort_order
  FROM area_stats_with_percentage
  WHERE rank <= 20
),
other_areas AS (
  SELECT
    'Other ' || COUNT(*) ||
    CASE
      WHEN MIN(area_name) LIKE 'Zip Code:%' THEN ' Postal Codes'
      ELSE ' Areas'  -- Areas includes both counties and cities
    END AS area_name,
    SUM(total_cases)::integer AS total_cases,
    ROUND(
      CASE
        WHEN SUM(total_cases) > 0 THEN
          SUM(total_cases * percentage_closed) / SUM(total_cases)
        ELSE 0
      END, 2
    ) AS percentage_closed,
    1 AS sort_order
  FROM area_stats_with_percentage
  WHERE rank > 20
),
combined_results AS (
  SELECT area_name, total_cases, percentage_closed, sort_order
  FROM top_areas

  UNION ALL

  SELECT area_name, total_cases, percentage_closed, sort_order
  FROM other_areas
  WHERE total_cases > 0
)

-- Final output with proper ordering
SELECT area_name, total_cases, percentage_closed
FROM combined_results
ORDER BY sort_order, total_cases DESC;
