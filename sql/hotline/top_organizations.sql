WITH top_orgs AS (
    SELECT
        COUNT(pds.id) AS call_count,
        uu.organization_id,
        oo.name
    FROM phone_dnis_statuses AS pds
    LEFT JOIN user_users AS uu
        ON pds.created_by = uu.id
    LEFT JOIN organization_organizations AS oo
        ON uu.organization_id = oo.id
    WHERE
        pds.inbound_id IN (
            SELECT id FROM phone_inbound WHERE string_to_array('175', ',')::int[] && incident_id
        )
        OR pds.outbound_id IN (
            SELECT id FROM phone_outbound WHERE string_to_array('175', ',')::int[] && incident_id
        )
    GROUP BY
        uu.organization_id,
        oo.name
    ORDER BY
        call_count DESC
    LIMIT 20
)
SELECT
    ROW_NUMBER() OVER (ORDER BY call_count DESC) AS "Top 20 Organizations by Calls",
    name AS "Name of Organization",
    call_count AS "Call Count"
FROM top_orgs;