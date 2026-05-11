-- Hotline heatmap data for Kepler.gl visualization
-- Generates area code call volumes with geographic data

SELECT pac.location_name AS area_name, 
       RIGHT(LEFT(pd.dnis::text,4),3)::integer AS area_code, 
       ll.geom, 
       ll.poly, 
       COUNT(DISTINCT pi.session_id) AS calls
FROM phone_inbound AS pi
LEFT JOIN phone_dnis AS pd ON pi.dnis_id = pd.id
LEFT JOIN phone_area_codes AS pac ON area_code = pac.code
LEFT JOIN location_locations ll ON ll.id = pac.location_id
LEFT JOIN location_types lt ON lt.id = ll.type_id
WHERE string_to_array('175', ',')::int[] && pi.incident_id -- Support multiple incident IDs: e.g., '175' or '175,172,180'
	AND lt.id = 32
GROUP BY 1, 2, 3, 4;