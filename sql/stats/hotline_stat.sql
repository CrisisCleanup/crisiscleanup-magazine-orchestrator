-- Hotline Statistics
-- Generates hotline-related statistics for magazine
-- Output: Two-column format with "Stat Name" and "Value"

WITH hotline_calls AS (
  -- Count distinct hotline calls using existing proven logic
  SELECT COUNT(DISTINCT pi.session_id) AS call_count
  FROM phone_inbound pi
  WHERE string_to_array('175', ',')::int[] && pi.incident_id
),
volunteer_activity AS (
  -- Get active volunteers using existing proven logic from hotline_volunteers_count.sql
  SELECT pds.created_by AS user_id
  FROM phone_dnis_statuses AS pds
  WHERE pds.inbound_id IN (
      SELECT id FROM phone_inbound WHERE string_to_array('175', ',')::int[] && incident_id
  )
  OR pds.outbound_id IN (
      SELECT id FROM phone_outbound WHERE string_to_array('175', ',')::int[] && incident_id
  )
),
hotline_volunteers AS (
  -- Count distinct volunteers using existing proven logic
  SELECT COUNT(DISTINCT user_id) AS volunteer_count
  FROM volunteer_activity
  WHERE user_id IS NOT NULL
),
active_volunteer_ids AS (
  -- Get active volunteer IDs using existing proven logic from hotline_organizations_count.sql
  SELECT DISTINCT pds.created_by AS user_id
  FROM phone_dnis_statuses AS pds
  WHERE pds.inbound_id IN (
      SELECT id FROM phone_inbound WHERE string_to_array('175', ',')::int[] && incident_id
  )
  OR pds.outbound_id IN (
      SELECT id FROM phone_outbound WHERE string_to_array('175', ',')::int[] && incident_id
  )
),
hotline_organizations AS (
  -- Count distinct organizations using existing proven logic
  SELECT COUNT(DISTINCT uu.organization_id) AS org_count
  FROM user_users AS uu
  JOIN active_volunteer_ids avi ON uu.id = avi.user_id
  WHERE uu.organization_id IS NOT NULL
),
hotline_days_open AS (
  -- Calculate days hotline was open - for multi-incident, sum all periods
  SELECT SUM(end_at - start_at) AS days_open
  FROM phone_anis_incidents
  WHERE incident_id = ANY(string_to_array('175', ',')::int[])
),
volunteer_service_periods AS (
  -- Calculate service period for each volunteer (first to last call)
  SELECT 
    pds.created_by AS user_id,
    MIN(pds.created_at) AS first_call,
    MAX(pds.created_at) AS last_call,
    EXTRACT(EPOCH FROM (MAX(pds.created_at) - MIN(pds.created_at))) / 86400.0 AS service_days
  FROM phone_dnis_statuses pds
  WHERE pds.inbound_id IN (
      SELECT id FROM phone_inbound WHERE string_to_array('175', ',')::int[] && incident_id
  )
  OR pds.outbound_id IN (
      SELECT id FROM phone_outbound WHERE string_to_array('175', ',')::int[] && incident_id
  )
  GROUP BY pds.created_by
  HAVING pds.created_by IS NOT NULL
),
average_hotline_service AS (
  -- Calculate average service period across all volunteers
  SELECT 
    ROUND(AVG(service_days), 1) AS avg_service_days
  FROM volunteer_service_periods
)

-- Final output in required format
SELECT 'Hotline Calls' AS "Stat Name",
       CASE WHEN hc.call_count >= 1000 
            THEN TO_CHAR(hc.call_count, 'FM999,999,999')
            ELSE hc.call_count::text 
       END AS "Value"
FROM hotline_calls hc

UNION ALL

SELECT 'Hotline Volunteers' AS "Stat Name",
       CASE WHEN hv.volunteer_count >= 1000 
            THEN TO_CHAR(hv.volunteer_count, 'FM999,999,999')
            ELSE hv.volunteer_count::text 
       END AS "Value"
FROM hotline_volunteers hv

UNION ALL

SELECT 'Average Call Length' AS "Stat Name",
       '7.5 mins' AS "Value"

UNION ALL

SELECT 'Hotline Organizations' AS "Stat Name",
       CASE WHEN ho.org_count >= 1000 
            THEN TO_CHAR(ho.org_count, 'FM999,999,999')
            ELSE ho.org_count::text 
       END AS "Value"
FROM hotline_organizations ho

UNION ALL

SELECT 'Days Hotline open' AS "Stat Name",
       hdo.days_open::text AS "Value"
FROM hotline_days_open hdo

UNION ALL

SELECT 'Average Hotline Service' AS "Stat Name",
       CASE 
         WHEN ahs.avg_service_days IS NULL THEN '0 days'
         WHEN ahs.avg_service_days < 1 THEN '< 1 day'
         ELSE ahs.avg_service_days::text || ' days'
       END AS "Value"
FROM average_hotline_service ahs;