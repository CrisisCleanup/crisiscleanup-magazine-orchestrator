SELECT DISTINCT(worksite_id)
FROM r.cases_new_claimed_closed_omni
WHERE home_indigenous_region_name IS NOT NULL
AND incident_id = ANY(string_to_array('175', ',')::int[]); -- Support multiple incident IDs: e.g., '175' or '175,172,180'