-- 9_daily_active_organizations.csv
-- Tracks daily organization activity (worksites, claims, status updates, calls)
-- HYBRID QUERY: Uses omni for worksite/claim data + direct queries for user/phone activity
-- NOTE: State filter applies only to worksite/claim activity (Sources 1 & 2)
--       Phone/status activity (Sources 3 & 4) includes all incident activity

WITH target_incident AS (
  -- Selects the target incidents
  -- Support for multiple incident IDs: e.g., '175' or '175,172,180'
  SELECT
    id,
    name,
    start_at,
    timezone
  FROM incident_incidents
  WHERE id = ANY(string_to_array('175', ',')::int[])
),
analysis_dates AS (
  -- Get all unique snapshot dates within analysis period from omni table
  -- NOTE: is_daily_last is NULL for most rows, so we don't filter by it
  SELECT DISTINCT the_date AS date_active
  FROM r.cases_new_claimed_closed_omni_mag
  WHERE incident_id = ANY(string_to_array('175', ',')::int[])
    AND is_within_analysis = true
    AND invalidated_at IS NULL
  ORDER BY the_date
),
org_activity AS (
  -- Source 1: Organizations that created worksites in this state (from omni)
  -- NOTE: is_daily_last is NULL for most rows, so we don't filter by it
  SELECT DISTINCT
    omni.the_date AS date_active,
    omni.ww_reported_by AS organization_id
  FROM r.cases_new_claimed_closed_omni_mag omni
  WHERE omni.incident_id = ANY(string_to_array('175', ',')::int[])
    AND omni.is_within_analysis = true
    AND RIGHT(COALESCE(omni.home_local_division_name, omni.home_city_name), 2) = 'STATE_PLACEHOLDER'  -- State filter
    AND omni.ww_reported_by IS NOT NULL
    AND omni.invalidated_at IS NULL

  UNION

  -- Source 2: Organizations that claimed work types in this state (from omni)
  SELECT DISTINCT
    omni.the_date AS date_active,
    omni.wwwtsp_claimed_by AS organization_id
  FROM r.cases_new_claimed_closed_omni_mag omni
  WHERE omni.incident_id = ANY(string_to_array('175', ',')::int[])
    AND omni.is_within_analysis = true
    AND RIGHT(COALESCE(omni.home_local_division_name, omni.home_city_name), 2) = 'STATE_PLACEHOLDER'  -- State filter
    AND omni.wwwtsp_claimed_by IS NOT NULL
    AND omni.invalidated_at IS NULL

  UNION

  -- Source 3: Organizations whose users updated work type statuses (incident-wide)
  SELECT DISTINCT
    DATE(w.created_at AT TIME ZONE 'UTC' AT TIME ZONE ti.timezone) AS date_active,
    uu.organization_id
  FROM worksite_worksites_work_types_statuses_phases AS w
  INNER JOIN target_incident ti ON ti.id = w.incident_id
  LEFT JOIN user_users AS uu ON w.work_type_created_by = uu.id
  CROSS JOIN (
    -- Get the date range from omni analysis period
    SELECT MIN(the_date) AS start_date, MAX(the_date) AS end_date
    FROM r.cases_new_claimed_closed_omni_mag
    WHERE incident_id = ANY(string_to_array('175', ',')::int[])
      AND is_within_analysis = true
  ) date_range
  WHERE DATE(w.created_at AT TIME ZONE 'UTC' AT TIME ZONE ti.timezone)
        BETWEEN date_range.start_date AND date_range.end_date
    AND uu.organization_id IS NOT NULL

  UNION

  -- Source 4: Organizations whose users took inbound calls (incident-wide)
  SELECT DISTINCT
    DATE(pi.created_at AT TIME ZONE 'UTC' AT TIME ZONE ti.timezone) AS date_active,
    uu.organization_id
  FROM phone_inbound AS pi
  INNER JOIN target_incident ti ON ti.id = ANY(pi.incident_id)
  LEFT JOIN user_users AS uu ON pi.created_by = uu.id
  CROSS JOIN (
    -- Get the date range from omni analysis period
    SELECT MIN(the_date) AS start_date, MAX(the_date) AS end_date
    FROM r.cases_new_claimed_closed_omni_mag
    WHERE incident_id = ANY(string_to_array('175', ',')::int[])
      AND is_within_analysis = true
  ) date_range
  WHERE DATE(pi.created_at AT TIME ZONE 'UTC' AT TIME ZONE ti.timezone)
        BETWEEN date_range.start_date AND date_range.end_date
    AND uu.organization_id IS NOT NULL
)
SELECT
  ad.date_active AS creation_date,
  COUNT(DISTINCT oa.organization_id) AS organizations
FROM analysis_dates ad
LEFT JOIN org_activity oa
  ON ad.date_active = oa.date_active
  AND oa.organization_id != 89  -- Exclude organization 89
GROUP BY ad.date_active
ORDER BY ad.date_active;
