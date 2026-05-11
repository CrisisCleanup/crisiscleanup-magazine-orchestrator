-- Volunteer location data for Kepler.gl visualization
-- Generates volunteer locations with call activity for mapping

WITH volunteer_incident_activity AS (
    SELECT pds.created_by AS user_id
    FROM phone_dnis_statuses AS pds
    WHERE pds.inbound_id IN (
        SELECT id FROM phone_inbound WHERE string_to_array('175', ',')::int[] && incident_id -- Support multiple incident IDs
    )
    OR pds.outbound_id IN (
        SELECT id FROM phone_outbound WHERE string_to_array('175', ',')::int[] && incident_id -- Support multiple incident IDs
    )
),
call_counts_by_user AS (
    SELECT
        user_id,
        COUNT(*) AS call_count
    FROM volunteer_incident_activity
    WHERE user_id IS NOT NULL
    GROUP BY user_id
),
most_recent_user_location AS (
    SELECT user_id, point
    FROM (
        SELECT
            user_id,
            point,
            ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY created_at DESC) AS rn
        FROM user_users_geo_locations
      	WHERE point IS NOT NULL
    ) AS ranked_locations
    WHERE rn = 1 
)
SELECT
    uu.id AS user_id,
    uu.first_name,
    uu.last_name,
    oo.name AS organization_name,
    mrl.point, 
    uu.current_sign_in_ip,
    cc.call_count
FROM call_counts_by_user cc
JOIN user_users AS uu ON cc.user_id = uu.id
LEFT JOIN organization_organizations AS oo ON uu.organization_id = oo.id
LEFT JOIN most_recent_user_location AS mrl ON cc.user_id = mrl.user_id
ORDER BY
    cc.call_count DESC;