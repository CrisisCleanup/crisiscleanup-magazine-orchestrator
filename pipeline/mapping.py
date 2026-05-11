"""Mappings from SQL files to CSV outputs.

Each entry describes one query the pipeline will run:

* ``sql`` -- path to the SQL file, relative to the ``sql/`` root.
* ``output`` -- base name of the CSV file (no extension).
* ``category`` -- subdirectory the CSV is written to.
"""

from dataclasses import dataclass


@dataclass(frozen=True)
class Query:
    sql: str
    output: str
    category: str


# Subdirectories created inside every output run.
OUTPUT_CATEGORIES = (
    "incident_overview",
    "state_summary",
    "county_summary",
    "hotline",
    "stats",
    "general",
    "marketing",
)


# Main incident-level visualisations.
INCIDENT_QUERIES: tuple[Query, ...] = (
    Query("general/history_of_incidents.sql",          "1_incident_history",              "general"),
    Query("incident_overview/orgs_only.sql",           "2_orgs_timeline",                 "incident_overview"),
    Query("incident_overview/calls_only.sql",          "2_calls_timeline",                "incident_overview"),
    Query("incident_overview/incident_bubbles.sql",    "3_bubble_plot",                   "incident_overview"),
    Query("hotline/us_heatmap.sql",                    "4_hotline_map",                   "hotline"),
    Query("hotline/volunteer_locations.sql",           "4_volunteer_locations_map",       "hotline"),
    Query("incident_overview/summary_worktypes.sql",   "5_worktype_donut",                "incident_overview"),
    Query("incident_overview/timeseries_overall.sql",  "6_cases_by_status",               "incident_overview"),
    Query("incident_overview/timeseries_worktypes.sql","7_worktype_closures",             "incident_overview"),
    Query("incident_overview/volunteer_engagement.sql","8_volunteer_engagement",          "incident_overview"),
    Query("incident_overview/organizations.sql",       "9_daily_active_organizations",    "incident_overview"),
    # The work-types summary feeds three outputs; the post-processor splits it.
    Query("incident_overview/summary_worktypes.sql",   "10_commercial_value_of_services", "incident_overview"),
    Query("incident_overview/summary_worktypes.sql",   "11_cases_by_worktype",            "incident_overview"),
    Query("incident_overview/svi_help.sql",            "12_needs_met_svi",                "incident_overview"),
    Query("incident_overview/svi_value.sql",           "13_commercial_value_svi",         "incident_overview"),
    Query("incident_overview/days_waiting_for_service.sql", "days_waiting_for_service",   "incident_overview"),
    Query("incident_overview/proportional_area_chart.sql",  "proportional_area_chart",    "incident_overview"),
    Query("hotline/calls_timeseries.sql",              "hotline_calls",                   "hotline"),
)


# State-level variants. One run per state in ``--state-list``; outputs are
# prefixed with the two-letter state code (e.g. ``MO_6_cases_by_status.csv``).
STATE_QUERIES: tuple[Query, ...] = (
    Query("state_summary/timeseries_overall.sql",      "6_cases_by_status",               "state_summary"),
    Query("state_summary/timeseries_worktypes.sql",    "7_worktype_closures",             "state_summary"),
    Query("state_summary/organizations.sql",           "9_daily_active_organizations",    "state_summary"),
    Query("state_summary/summary_worktypes.sql",       "11_cases_by_worktype",            "state_summary"),
    Query("state_summary/svi_help.sql",                "12_needs_met_svi",                "state_summary"),
    Query("state_summary/svi_value.sql",               "13_commercial_value_svi",         "state_summary"),
    Query("state_summary/proportional_area_chart.sql", "proportional_area_chart",         "state_summary"),
)


# County-level queries. Same execution model as state-level: one run per state
# in ``--state-list``. The output CSV is the input to ``publish_infogram`` for
# the per-county PDF export.
COUNTY_QUERIES: tuple[Query, ...] = (
    Query("county_summary/commercial_value.sql",       "commercial_value",                "county_summary"),
)


# Supporting queries -- single statements that feed magazine sidebars and
# stats-page text. Output files are written with the ``supporting_`` prefix.
SUPPORTING_QUERIES: tuple[Query, ...] = (
    Query("hotline/first_call.sql",            "supporting_first_call",            "hotline"),
    Query("hotline/top_area_codes.sql",        "supporting_top_area_codes",        "hotline"),
    Query("hotline/top_organizations.sql",     "supporting_top_organizations",     "hotline"),
    Query("hotline/top_volunteers.sql",        "supporting_top_volunteers",        "hotline"),
    Query("hotline/volunteer_locations.sql",   "supporting_volunteer_locations",   "hotline"),

    Query("general/back_cover.sql",            "supporting_back_cover",            "general"),
    Query("general/phone_volunteers.sql",      "supporting_phone_volunteers",      "general"),
    Query("general/tribal_case_count.sql",     "supporting_tribal_case_count",     "general"),

    Query("marketing/users_participating.sql", "supporting_users_participating",   "marketing"),

    Query("stats/front_cover.sql",             "supporting_front_cover",           "stats"),
    Query("stats/history_stat.sql",            "supporting_history_stat",          "stats"),
    Query("stats/history_insights.sql",        "supporting_history_insights",      "stats"),
    Query("stats/hotline_stat.sql",            "supporting_hotline_stat",          "stats"),
    Query("stats/volunteer_stat.sql",          "supporting_volunteer_stat",        "stats"),
    Query("stats/volunteer_insights.sql",      "supporting_volunteer_insights",    "stats"),
    Query("stats/service_stat.sql",            "supporting_service_stat",          "stats"),
    Query("stats/service_insights.sql",        "supporting_service_insights",      "stats"),
    Query("stats/state_summary_stat.sql",      "supporting_state_summary_stat",    "stats"),
    Query("stats/state_summary_insights.sql",  "supporting_state_summary_insights","stats"),
    Query("stats/service_title.sql",           "supporting_service_title",         "stats"),
)
