WITH q AS(
	SELECT work_type_created_by AS user_id
	FROM worksite_worksites_work_types_statuses_phases
	WHERE incident_id = ANY(string_to_array('175', ',')::int[]) -- Support multiple incident IDs: e.g., '175' or '175,172,180'

	UNION ALL

	SELECT created_by
	FROM phone_dnis_statuses
	WHERE outbound_id IN(
		SELECT id
		FROM phone_outbound
		WHERE incident_id && string_to_array('175', ',')::int[] -- Support multiple incident IDs: e.g., '175' or '175,172,180'
	)
	OR inbound_id IN(
		SELECT id
		FROM phone_outbound
		WHERE incident_id && string_to_array('175', ',')::int[] -- Support multiple incident IDs: e.g., '175' or '175,172,180'
	)
)
SELECT uu.id, uu.first_name, uu.last_name, uu.email, uu.organization_id, oo.name
FROM user_users AS uu
LEFT JOIN organization_organizations AS oo
ON uu.organization_id = oo.id
WHERE uu.id IN(
	SELECT DISTINCT(user_id)
	FROM q
)
AND organization_id IS NOT NULL
AND LOWER(uu.password) NOT LIKE '%deleted%'
ORDER BY last_name, first_name;
