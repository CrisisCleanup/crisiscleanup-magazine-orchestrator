SELECT the_date AS creation_date,
			 velocity*100 AS engagement
FROM pp_engagement 
WHERE incident_id = ANY(string_to_array('175', ',')::int[]) -- Support multiple incident IDs: e.g., '175' or '175,172,180'
ORDER BY the_date;