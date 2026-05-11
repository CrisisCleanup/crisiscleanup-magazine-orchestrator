WITH incident_call_links AS (
    SELECT pds.created_by, pds.created_at
    FROM phone_dnis_statuses AS pds
    WHERE pds.inbound_id IN (
        SELECT id FROM phone_inbound WHERE incident_id && string_to_array('175', ',')::int[]
    )
    OR pds.outbound_id IN (
        SELECT id FROM phone_outbound WHERE incident_id && string_to_array('175', ',')::int[]
    )
),

incident_call_counts_by_user AS (
    SELECT
        created_by AS user_id,
        COUNT(*) AS total_incident_calls
    FROM incident_call_links
    GROUP BY created_by
),

first_ever_call_by_user AS (
    SELECT
        icl.created_by AS user_id,
        MIN(pds.created_at) AS first_ever_call_at
    FROM incident_call_links icl
    JOIN phone_dnis_statuses pds ON icl.created_by = pds.created_by
    GROUP BY icl.created_by
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
),

volunteer_locations AS (
    SELECT 
        mrl.user_id,
        COALESCE(
            (SELECT CONCAT(REGEXP_REPLACE(ll.name, ' County.*$', ''), ', ', RIGHT(ll.name, 2))
             FROM location_locations ll
             WHERE (ST_Contains(ST_Multi(ll.poly), mrl.point) 
                OR ST_Contains(ST_Multi(ll.geom), mrl.point))
               AND ll.type_id IN (SELECT id FROM location_types WHERE key = 'boundary_political_home_local_division')
               AND ll.created_by = 14
               AND ll.name ~ '.*, [A-Z]{2}$'  -- Must end with comma + 2 letter state code
               AND LENGTH(ll.name) > 4       -- Must be longer than just state code
               AND ll.name NOT LIKE '%Time Zone%'  -- Exclude time zone entries
             ORDER BY ST_Area(COALESCE(ll.poly, ll.geom)) ASC  -- Prefer smaller/more specific areas
             LIMIT 1),
            'Location Unknown'
        ) AS location_display
    FROM most_recent_user_location mrl
),

top_volunteers AS (
    SELECT
        uu.id AS user_id,
        uu.first_name,
        uu.last_name,
        oo.name AS organization_name, 
        icc.total_incident_calls AS call_count, 
        fec.first_ever_call_at AS member_since,
        vl.location_display
    FROM user_users AS uu
    LEFT JOIN organization_organizations AS oo ON uu.organization_id = oo.id
    LEFT JOIN volunteer_locations vl ON uu.id = vl.user_id
    JOIN first_ever_call_by_user fec ON uu.id = fec.user_id
    JOIN incident_call_counts_by_user icc ON uu.id = icc.user_id
    ORDER BY icc.total_incident_calls DESC
    LIMIT 6
)

SELECT
    ROW_NUMBER() OVER (ORDER BY call_count DESC) AS "Top 6 volunteers",
    CONCAT(first_name, ' ', last_name) AS "First & Last Name",
    COALESCE(location_display, 'Location Unknown') AS "Location of Volunteer",
    TO_CHAR(member_since, 'FMMonth YYYY') AS "Member since",
    COALESCE(organization_name, 'Independent') AS "Organization",
    call_count AS "Number of calls"
FROM top_volunteers;