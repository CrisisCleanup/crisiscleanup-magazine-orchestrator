-- County-level commercial value by work type for the requested state list.
-- Output columns: name, location_id, work_type_key, closed_commercial_value,
--                 open_claimed_value, open_unclaimed_value
--
-- Granularity: one row per county/area + work type. "Area" falls back to the
-- city name when the worksite is in an independent city not contained in any
-- county polygon (e.g. St. Louis City, Baltimore City).

WITH target_incident AS (
  SELECT
    id,
    name,
    start_at,
    timezone
  FROM incident_incidents
  WHERE id = ANY(string_to_array('175', ',')::int[])
),
worksites_in_period AS (
  -- Capture every worksite that appears in the analysis window, regardless of
  -- whether it was created before or during the window.
  SELECT DISTINCT
    omni.worksite_id,
    omni.home_local_division_name AS county_name,
    omni.home_city_name,
    omni.home_postal_code_name,
    RIGHT(COALESCE(omni.home_local_division_name, omni.home_city_name), 2) AS home_state
  FROM r.cases_new_claimed_closed_omni_mag omni
  WHERE omni.incident_id = ANY(string_to_array('175', ',')::int[])
    AND omni.is_within_analysis = true
    AND omni.invalidated_at IS NULL
    AND RIGHT(COALESCE(omni.home_local_division_name, omni.home_city_name), 2)
        = ANY(string_to_array(REPLACE('STATE_LIST_PLACEHOLDER', ' ', ''), ','))
),
end_of_period_snapshot AS (
  -- Latest snapshot of each (worksite, work_type) within the analysis window.
  SELECT DISTINCT ON (omni.worksite_id, omni.work_type_key)
    omni.worksite_id,
    omni.work_type_key,
    omni.work_type_value,
    omni.percent_closed_hash,
    omni.wwwtsp_claimed_by
  FROM r.cases_new_claimed_closed_omni_mag omni
  INNER JOIN worksites_in_period wp ON omni.worksite_id = wp.worksite_id
  WHERE omni.incident_id = ANY(string_to_array('175', ',')::int[])
    AND omni.is_within_analysis = true
    AND omni.invalidated_at IS NULL
    AND omni.work_type_key NOT IN ('mold_remediation', 'rebuild', 'heating', 'shopping', 'report')
  ORDER BY omni.worksite_id, omni.work_type_key, omni.the_date DESC, omni.created_at DESC
),
worksite_area AS (
  -- One area label per worksite (county or independent city).
  SELECT
    wp.worksite_id,
    COALESCE(wp.county_name, wp.home_city_name) AS area_name
  FROM worksites_in_period wp
),
work_type_values AS (
  SELECT
    eps.work_type_key,
    wa.area_name,
    eps.work_type_value,
    eps.percent_closed_hash,
    eps.wwwtsp_claimed_by,
    eps.work_type_value * eps.percent_closed_hash AS closed_value,
    eps.work_type_value * (1 - eps.percent_closed_hash) AS open_value
  FROM end_of_period_snapshot eps
  INNER JOIN worksite_area wa ON eps.worksite_id = wa.worksite_id
),
area_worktype_aggregates AS (
  SELECT
    area_name,
    work_type_key,
    SUM(closed_value) AS closed_commercial_value,
    SUM(open_value) FILTER (WHERE wwwtsp_claimed_by IS NOT NULL) AS open_claimed_value,
    SUM(open_value) FILTER (WHERE wwwtsp_claimed_by IS NULL)     AS open_unclaimed_value
  FROM work_type_values
  WHERE area_name IS NOT NULL
  GROUP BY area_name, work_type_key
),
location_lookup AS (
  -- Resolve a stable location_id for each area name. Used only to give the
  -- exported PDFs a deterministic filename.
  SELECT DISTINCT ON (ll.name)
    ll.name AS area_name,
    ll.id   AS location_id
  FROM location_locations ll
  INNER JOIN location_types lt ON ll.type_id = lt.id
  WHERE lt.key IN ('boundary_political_home_local_division', 'boundary_political_home_city')
    AND RIGHT(ll.name, 2) = ANY(string_to_array(REPLACE('STATE_LIST_PLACEHOLDER', ' ', ''), ','))
  ORDER BY ll.name, ll.id
)
SELECT
  awa.area_name                       AS name,
  ll.location_id,
  awa.work_type_key,
  COALESCE(awa.closed_commercial_value, 0)  AS closed_commercial_value,
  COALESCE(awa.open_claimed_value, 0)       AS open_claimed_value,
  COALESCE(awa.open_unclaimed_value, 0)     AS open_unclaimed_value
FROM area_worktype_aggregates awa
LEFT JOIN location_lookup ll ON ll.area_name = awa.area_name
ORDER BY awa.area_name, awa.work_type_key;
