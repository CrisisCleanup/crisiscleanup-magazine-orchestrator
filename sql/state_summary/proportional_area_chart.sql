-- State-Specific Proportional Area Chart: Geographic Case Distribution
-- Output: Three-column format with "area", "total_cases", "percentage_closed"
-- Uses counties by default, switches to postal codes when ≤4 counties have cases within the specified state

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
-- Check county count across entire incident to determine granularity level (consistent with incident-overview logic)
incident_county_count_check AS (
  SELECT 
    COUNT(DISTINCT aw.county) AS total_counties
  FROM worksite_worksites aw
  INNER JOIN target_incident ti ON aw.incident_id = ti.id
  CROSS JOIN report_period rp
  WHERE aw.invalidated_at IS NULL
    AND aw.county IS NOT NULL
    AND aw.county != ''
    AND DATE(aw.created_at AT TIME ZONE 'UTC' AT TIME ZONE ti.timezone)
          BETWEEN rp.report_start_date AND rp.report_end_date
),
temp_worksites AS (
    SELECT DISTINCT ww.id, ww.incident_id, ww.location, ww.state,
        CASE
            WHEN ww.state IS NULL THEN true
            ELSE null
        END AS select_worksite,
        ROW_NUMBER() OVER(PARTITION BY ww.state ORDER BY RANDOM()) AS row_num
    FROM worksite_worksites ww
    INNER JOIN target_incident ti ON ww.incident_id = ti.id
    WHERE ww.invalidated_at IS NULL
),
all_worksites AS (
    SELECT ww.id AS worksite_id, ww.incident_id, ww.location, ww.state
    FROM worksite_worksites ww
    INNER JOIN temp_worksites tw
      ON tw.id = ww.id
      AND (tw.row_num <= 10000 OR tw.select_worksite IS TRUE)
),
-- Geographic areas based on incident county count (counties if >4, postal codes if ≤4)
geographic_areas AS (
  SELECT DISTINCT
    CASE
      WHEN iccc.total_counties > 4 THEN 
        -- Use county data filtered by state
        (SELECT ll_county.name 
         FROM location_locations ll_county
         WHERE (ST_Contains(ST_Multi(ll_county.poly), tws.location) OR ST_Contains(ST_Multi(ll_county.geom), tws.location))
           AND ll_county.type_id IN (SELECT id FROM location_types WHERE key = 'boundary_political_home_local_division')
           AND ll_county.created_by = 14
           AND RIGHT(ll_county.name, 2) = 'STATE_PLACEHOLDER'
         LIMIT 1)
      ELSE 
        -- Use postal code data filtered by state
        (SELECT ll_postal.name 
         FROM location_locations ll_postal
         WHERE (ST_Contains(ST_Multi(ll_postal.poly), tws.location) OR ST_Contains(ST_Multi(ll_postal.geom), tws.location))
           AND ll_postal.type_id IN (SELECT id FROM location_types WHERE key = 'boundary_political_home_postal_code')
           AND ll_postal.created_by = 14
         LIMIT 1)
    END AS area_name,
    tws.worksite_id
  FROM all_worksites tws
  CROSS JOIN incident_county_count_check iccc
  WHERE CASE
    WHEN iccc.total_counties > 4 THEN 
      EXISTS (SELECT 1 FROM location_locations ll_county
              WHERE (ST_Contains(ST_Multi(ll_county.poly), tws.location) OR ST_Contains(ST_Multi(ll_county.geom), tws.location))
                AND ll_county.type_id IN (SELECT id FROM location_types WHERE key = 'boundary_political_home_local_division')
                AND ll_county.created_by = 14
                AND RIGHT(ll_county.name, 2) = 'STATE_PLACEHOLDER')
    ELSE 
      EXISTS (SELECT 1 FROM location_locations ll_postal
              WHERE (ST_Contains(ST_Multi(ll_postal.poly), tws.location) OR ST_Contains(ST_Multi(ll_postal.geom), tws.location))
                AND ll_postal.type_id IN (SELECT id FROM location_types WHERE key = 'boundary_political_home_postal_code')
                AND ll_postal.created_by = 14)
  END
),
-- Use STANDARDIZED logic from incident_summary_overall.sql for case status
work_type_values AS (
  SELECT
    aw.worksite_id,
    ga.area_name,
    aw.state,
    wwt.commercial_value * (1 - wws.completed_by_anybody) AS open_value,
    wwt.commercial_value * wws.completed_by_anybody AS closed_value,
    wwt.commercial_value AS total_value,
    (wwwtsp.work_type_claimed_by IS NOT NULL) AS is_claimed,
    (wws.primary_state = 'open') AS is_open
  FROM all_worksites aw
  INNER JOIN target_incident ti ON aw.incident_id = ti.id
  INNER JOIN worksite_worksites ww_orig ON aw.worksite_id = ww_orig.id
  INNER JOIN geographic_areas ga ON aw.worksite_id = ga.worksite_id
  CROSS JOIN report_period rp
  LEFT JOIN worksite_worksites_work_types_statuses_phases wwwtsp ON aw.worksite_id = wwwtsp.worksite_id
  LEFT JOIN worksite_work_statuses wws ON wwwtsp.status_key = wws.status
  LEFT JOIN worksite_work_types wwt ON wwwtsp.work_type_key = wwt.key
  WHERE wwwtsp.invalidated_at IS NULL
    AND ga.area_name IS NOT NULL
    AND DATE(ww_orig.created_at AT TIME ZONE 'UTC' AT TIME ZONE ti.timezone)
          BETWEEN rp.report_start_date AND rp.report_end_date
),
worksite_ratios AS (
  SELECT
    worksite_id,
    area_name,
    state,
    SUM(open_value) FILTER (WHERE is_claimed AND is_open) AS open_claimed_value,
    SUM(open_value) FILTER (WHERE NOT is_claimed AND is_open) AS open_unclaimed_value,
    SUM(closed_value) AS total_closed_value,
    SUM(total_value) AS total_worksite_value
  FROM work_type_values
  GROUP BY worksite_id, area_name, state
),
area_stats AS (
  SELECT
    -- For counties: just use the county name (e.g., "Guadalupe")
    -- For postal codes: format as "Zip Code: NNNNN"
    CASE
      WHEN (SELECT total_counties FROM incident_county_count_check) > 4 THEN
        -- County mode: remove " County" suffix (e.g., "Llano County" -> "Llano")
        REGEXP_REPLACE(area_name, ' County$', '')
      ELSE
        -- Postal code mode: format as "Zip Code: NNNNN"
        'Zip Code: ' || REGEXP_REPLACE(area_name, '^Zip Code ', '')
    END AS area_name,
    state,
    COUNT(worksite_id)::integer AS total_cases,  -- Ensure integer format
    ROUND(
      COALESCE(SUM(total_closed_value / NULLIF(total_worksite_value, 0)), 0)
    ) AS closed_cases
  FROM worksite_ratios
  WHERE area_name IS NOT NULL
  GROUP BY
    CASE
      WHEN (SELECT total_counties FROM incident_county_count_check) > 4 THEN
        REGEXP_REPLACE(area_name, ' County$', '')
      ELSE
        'Zip Code: ' || REGEXP_REPLACE(area_name, '^Zip Code ', '')
    END, state
),
area_stats_with_percentage AS (
  SELECT
    area_name,
    state,
    total_cases,
    ROUND(
      CASE 
        WHEN total_cases > 0 THEN closed_cases / total_cases::numeric
        ELSE 0
      END, 2
    ) AS percentage_closed,  -- Decimal format (e.g., 0.33 instead of 33)
    ROW_NUMBER() OVER (ORDER BY total_cases DESC) as rank
  FROM area_stats
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
      WHEN (SELECT total_counties FROM incident_county_count_check) > 4 THEN ' Counties'
      ELSE ' Postal Codes'
    END AS area_name,
    SUM(total_cases)::integer AS total_cases,  -- Ensure integer format
    ROUND(
      CASE 
        WHEN SUM(total_cases) > 0 THEN 
          SUM(total_cases * percentage_closed) / SUM(total_cases)  -- Already in decimal format
        ELSE 0
      END, 2
    ) AS percentage_closed,  -- Decimal format (e.g., 0.33)
    1 AS sort_order
  FROM area_stats_with_percentage
  CROSS JOIN incident_county_count_check
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