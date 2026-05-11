SELECT COUNT(pds.id) AS call_count, pds.created_by AS user_id, uu.first_name, uu.last_name, oo.name
FROM phone_dnis_statuses AS pds
LEFT JOIN user_users AS uu
ON pds.created_by = uu.id
LEFT JOIN organization_organizations AS oo
ON uu.organization_id = oo.id
WHERE pds.created_at > '2024-09-24'
AND pds.created_at < '2024-10-08'
GROUP BY pds.created_by, uu.first_name, uu.last_name, oo.name
ORDER BY call_count DESC
LIMIT 7;

SELECT pds.created_at
FROM phone_dnis_statuses AS pds
ORDER BY created_at ASC
LIMIT 1;