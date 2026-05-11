
WITH q AS(

	-- All organizations that created new worksites
	SELECT ww.reported_by AS organization_id, oo.name, oo.type_t AS org_type, ww.id AS worksite_id, og.name AS group_name
	FROM worksite_worksites AS ww
	LEFT JOIN organization_organizations AS oo
	ON ww.reported_by = oo.id
	LEFT JOIN organization_organizations_groups AS oog
	ON oo.id = oog.organization_id
	LEFT JOIN organization_groups AS og
	ON oog.group_id = og.id
	WHERE incident_id = ANY(string_to_array('175', ',')::int[]) -- Support multiple incident IDs: e.g., '175' or '175,172,180'
	AND ww.invalidated_at IS NULL

	UNION ALL
	
	-- All organizations that claimed a work_type
	SELECT w.work_type_claimed_by AS organization_id,  oo.name, oo.type_t AS org_type, w.worksite_id AS worksite_id,  og.name
	FROM worksite_worksites_work_types_statuses_phases AS w
	LEFT JOIN organization_organizations AS oo
	ON w.work_type_claimed_by = oo.id
	LEFT JOIN organization_organizations_groups AS oog
	ON oo.id = oog.organization_id
	LEFT JOIN organization_groups AS og
	ON oog.group_id = og.id
	WHERE w.incident_id = ANY(string_to_array('175', ',')::int[]) -- Support multiple incident IDs: e.g., '175' or '175,172,180'

	UNION ALL
	
	-- All organizations whose users updated a work_type status
	SELECT oo.id AS organization_id, oo.name, oo.type_t AS org_type, w.worksite_id AS worksite_id, og.name
	FROM worksite_worksites_work_types_statuses_phases AS w
	LEFT JOIN user_users AS uu
	ON w.work_type_created_by = uu.id
	LEFT JOIN organization_organizations AS oo
	ON uu.organization_id = oo.id
	LEFT JOIN organization_organizations_groups AS oog
	ON oo.id = oog.organization_id
	LEFT JOIN organization_groups AS og
	ON oog.group_id = og.id
	WHERE w.incident_id = ANY(string_to_array('175', ',')::int[]) -- Support multiple incident IDs: e.g., '175' or '175,172,180'
	
	UNION ALL

	-- All organizations whose users took an inbound call
	SELECT uu.organization_id, oo.name, oo.type_t AS org_type, null AS worksite_id, og.name
	FROM phone_inbound AS pi
	LEFT JOIN user_users AS uu
	ON pi.created_by = uu.id
	LEFT JOIN organization_organizations AS oo
	ON uu.organization_id = oo.id
	LEFT JOIN organization_organizations_groups AS oog
	ON oo.id = oog.organization_id
	LEFT JOIN organization_groups AS og
	ON oog.group_id = og.id
	WHERE pi.incident_id && string_to_array('175', ',')::int[] -- Support multiple incident IDs: e.g., '175' or '175,172,180'

	UNION ALL

	-- All organizations whose users made an outbound call
	SELECT uu.organization_id, oo.name, oo.type_t AS org_type, null AS worksite_id, og.name
	FROM phone_outbound AS po
	LEFT JOIN user_users AS uu
	ON po.created_by = uu.id
	LEFT JOIN organization_organizations AS oo
	ON uu.organization_id = oo.id
	LEFT JOIN organization_organizations_groups AS oog
	ON oo.id = oog.organization_id
	LEFT JOIN organization_groups AS og
	ON oog.group_id = og.id
	WHERE po.created_at > (
		SELECT MIN(start_at)
		FROM phone_anis_incidents
		WHERE incident_id = ANY(string_to_array('175', ',')::int[]) -- Support multiple incident IDs: e.g., '175' or '175,172,180'
	)
	AND po.created_at < (
		SELECT MAX(end_at)
		FROM phone_anis_incidents
		WHERE incident_id = ANY(string_to_array('175', ',')::int[]) -- Support multiple incident IDs: e.g., '175' or '175,172,180'
	)
	AND uu.organization_id <> 89
	
	UNION ALL

	-- All government and voads, even if they didn't do anything
	SELECT ooi.organization_id, oo.name, oo.type_t AS org_type, null, og.name
	FROM organization_organizations_incidents AS ooi
	LEFT JOIN organization_organizations AS oo
	ON ooi.organization_id = oo.id
	LEFT JOIN organization_organizations_groups AS oog
	ON oo.id = oog.organization_id
	LEFT JOIN organization_groups AS og
	ON oog.group_id = og.id
	WHERE ooi.incident_id = ANY(string_to_array('175', ',')::int[]) -- Support multiple incident IDs: e.g., '175' or '175,172,180'
	AND ooi.invalidated_at IS NULL
	AND (oo.type_t = 'orgType.government'
		 OR oo.type_t = 'orgType.voad'
		 OR oo.type_t = 'orgType.coad')
	
)
SELECT DISTINCT(organization_id), name, REPLACE(org_type, 'orgType.', '') AS org_type, COUNT(DISTINCT(worksite_id)) AS worksite_count, group_name
FROM q
WHERE organization_id <> 89
GROUP BY organization_id, name, org_type, group_name
ORDER BY org_type, worksite_count DESC;