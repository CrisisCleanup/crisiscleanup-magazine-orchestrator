"""SQL placeholder substitution.

The SQL templates ship with a fixed sentinel incident ID (``175``) and named
placeholders for state and incident type. At runtime the caller's parameters
are substituted into each query before execution.
"""

import re


# Maps a user-supplied incident type to the grouped category used in
# ``front_cover.sql``. Anything not in the map passes through unchanged.
INCIDENT_TYPE_GROUPS = {
    "contaminated_water": "Other",
    "snow": "Snow & Ice",
    "ice_storm": "Snow & Ice",
    "volcano": "Earthquake & Volcano",
    "earthquake": "Earthquake & Volcano",
    "flood": "Flood",
    "mudslide": "Flood",
    "hurricane": "Hurricanes & Tropical Storms",
    "tropical_storm": "Hurricanes & Tropical Storms",
    "wind": "Severe Weather",
    "hail": "Severe Weather",
    "flood_tornado_wind": "Severe Weather",
    "flood_tstorm": "Severe Weather",
    "tornado": "Tornado",
    "fire": "Fire",
    "rebuild": "Rebuild",
    "virus": "Other",
}


# Recognises every form of the sentinel ``string_to_array('<digits>', ',')::int[]``
# that appears in the SQL templates, regardless of which numeric ID was baked in.
_SENTINEL_ARRAY = re.compile(r"string_to_array\('\d+',\s*','\)::int\[\]")


def apply_incident_ids(sql: str, incident_ids: str) -> str:
    """Replace the sentinel incident-ID array with the caller's IDs."""
    replacement = f"string_to_array('{incident_ids}', ',')::int[]"
    return _SENTINEL_ARRAY.sub(replacement, sql)


def apply_incident_type(sql: str, incident_type: str | None) -> str:
    """Replace ``INCIDENT_TYPE_PLACEHOLDER`` with the grouped category name.

    If no incident type is provided, the quoted placeholder is replaced with
    SQL ``NULL`` so the query evaluates against every type.
    """
    if incident_type:
        category = INCIDENT_TYPE_GROUPS.get(incident_type.lower(), incident_type)
        return sql.replace("INCIDENT_TYPE_PLACEHOLDER", category)
    return sql.replace("'INCIDENT_TYPE_PLACEHOLDER'", "NULL")


def apply_state_list(sql: str, state_list: str | None) -> str:
    """Replace ``STATE_LIST_PLACEHOLDER`` with a comma-separated state list."""
    if state_list:
        return sql.replace("STATE_LIST_PLACEHOLDER", state_list)
    return sql.replace("'STATE_LIST_PLACEHOLDER'", "NULL")


def apply_state(sql: str, state: str | None) -> str:
    """Replace ``STATE_PLACEHOLDER`` with a single state code.

    When no state is supplied, any line referencing the placeholder is dropped
    entirely so the query falls back to its unfiltered form.
    """
    if state:
        return sql.replace("STATE_PLACEHOLDER", state)
    return "\n".join(line for line in sql.splitlines() if "STATE_PLACEHOLDER" not in line)


def apply_all(
    sql: str,
    *,
    incident_ids: str,
    state: str | None = None,
    state_list: str | None = None,
    incident_type: str | None = None,
) -> str:
    """Apply every substitution in the right order."""
    sql = apply_incident_ids(sql, incident_ids)
    sql = apply_state(sql, state)
    sql = apply_state_list(sql, state_list)
    sql = apply_incident_type(sql, incident_type)
    return sql
