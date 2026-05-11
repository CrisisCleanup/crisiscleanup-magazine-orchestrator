WITH top_area_codes AS (
    SELECT 
        CONCAT(RIGHT(LEFT(pd.dnis::text,4),3)::integer,': ',pac.location_name, ', ',substr(ll.name, 16,2)) AS area_code_label,
        COUNT(DISTINCT pi.session_id) AS calls
    FROM phone_inbound AS pi
    LEFT JOIN phone_dnis AS pd ON pi.dnis_id = pd.id
    LEFT JOIN phone_area_codes AS pac ON area_code = pac.code
    LEFT JOIN location_locations ll ON ll.id = pac.location_id
    LEFT JOIN location_types lt ON lt.id = ll.type_id
    WHERE string_to_array('175', ',')::int[] && pi.incident_id
        AND lt.id = 32
    GROUP BY 1
    ORDER BY 2 DESC
    LIMIT 20
)
SELECT
    ROW_NUMBER() OVER (ORDER BY calls DESC) AS "Top 20 Area Codes by Calls",
    area_code_label AS "Area Code",
    calls AS "Call Count"
FROM top_area_codes;