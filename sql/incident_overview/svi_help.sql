-- 12_needs_met_svi.csv
-- NOTE: Post-processing ensures all 10 SVI buckets (0.0-0.1 through 0.9-1.0) are present

WITH target_incident AS (
  -- Selects the target incidents
  -- Support for multiple incident IDs: e.g., '175' or '175,172,180'
  SELECT
    id,
    name,
    start_at,
    timezone
  FROM incident_incidents
  WHERE id = ANY(string_to_array('175', ',')::int[])
),
worksites_with_svi AS (
  -- Get SVI from worksite table for all worksites in analysis period
  SELECT DISTINCT
    omni.worksite_id,
    ww.svi
  FROM r.cases_new_claimed_closed_omni_mag omni
  INNER JOIN worksite_worksites ww ON omni.worksite_id = ww.id
  WHERE omni.incident_id = ANY(string_to_array('175', ',')::int[])
    AND omni.is_within_analysis = true
    AND ww.svi IS NOT NULL
    AND omni.invalidated_at IS NULL
),
latest_work_type_snapshot AS (
  -- Get the latest snapshot for each work type using DISTINCT ON
  SELECT DISTINCT ON (omni.worksite_id, omni.work_type_key)
    omni.worksite_id,
    omni.work_type_key,
    omni.work_type_value,
    omni.percent_closed_hash
  FROM r.cases_new_claimed_closed_omni_mag omni
  INNER JOIN worksites_with_svi ws ON omni.worksite_id = ws.worksite_id
  WHERE omni.incident_id = ANY(string_to_array('175', ',')::int[])
    AND omni.is_within_analysis = true
    AND omni.work_type_key NOT IN ('mold_remediation', 'rebuild', 'heating')
    AND omni.invalidated_at IS NULL
  ORDER BY omni.worksite_id, omni.work_type_key, omni.the_date DESC, omni.created_at DESC
),
end_of_period_snapshot AS (
  SELECT
    CONCAT(
      LPAD(CAST(FLOOR(ws.svi * 10) / 10.0 AS TEXT), 3, '0'),
      ' - ',
      LPAD(CAST((FLOOR(ws.svi * 10) + 1) / 10.0 AS TEXT), 3, '0')
    ) AS svi_bin,
    SUM(lwts.work_type_value) AS total_commercial_value,
    SUM(lwts.work_type_value * lwts.percent_closed_hash) AS closed_commercial_value
  FROM latest_work_type_snapshot lwts
  INNER JOIN worksites_with_svi ws ON lwts.worksite_id = ws.worksite_id
  GROUP BY svi_bin
)
SELECT
  svi_bin,
  CONCAT(
    ROUND(
      closed_commercial_value / NULLIF(total_commercial_value, 0) * 100, 0
    ), '%'
  ) AS percentage
FROM end_of_period_snapshot
ORDER BY svi_bin DESC;
