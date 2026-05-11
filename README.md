# Crisis Cleanup Magazine Orchestrator

This repo contains the data analysis workflow and aggregation procedure for all stats, visualizations, natural language captions, and maps in Crisis Cleanup magazine. These outputs summarize the social and financial impact of volunteer response to natural disasters. The orchestrator serves as the automated reporting pipeline that produces analyses of Crisis Cleanup operational database following a natural disaster. The database itself contains details on disaster incidents, volunteer services, commercial value of remediation, and volunteer outcomes. The magazine orchestrator is click-of-a-button generation of all analysis outputs for the magazine which are exported into visualization tooling. It also produces automated natural language captions, referred here as "insights", that accompany visualizations in our reporting. 

```
PostgreSQL  ->  orchestrator  ->  formatted outputs  ->
visualization (Infogram, ggplot2, Tableau, kepler.gl)  ->  PDF
```

## What It Does

For one or more incident IDs (natural disasters) the pipeline runs roughly 40 SQL queries and
writes formatted outputs into a single directory tree, which is then consumed by all visualization tools. This includes national, state, and county level outputs. 
The queries are split into three groups:

- **Incident-overview** charts (donuts, timeseries, SVI breakdowns,
  proportional-area maps) describing the whole response.
- **State-summary** variants of those charts, one set per state passed to
  `--state-list`.
- **Supporting** files that feed the front cover, back cover, hotline stats
  and other sidebar text in the published report.

After the queries run, the pipeline applies a number of post-processing steps
that the visualization tooling requires: cumulative sums on the timeseries, an
alternating-label format on the date axis, completion of all ten Social
Vulnerability Index buckets, splitting of the combined work-type query into
case-count and commercial-value flavours, one donut CSV per work type, etc.

Everything that ran is captured in `run_report.json` for audit.

## Data Model

Heavy lifting is done by a PostgreSQL materialised view called
`r.cases_new_claimed_closed_omni_mag`. It is a denormalised, snapshot-level
view of cases joined to work types, statuses, incidents and pre-computed
geography. Most of the SQL templates query that view; a handful join back to
source tables for things the view does not store (user activity, phone calls,
SVI on the worksite record).

Two flags on the view drive most queries:

- `is_within_analysis = true` -- restricts to the 60-day reporting window
  for the incident.
- `invalidated_at IS NULL` -- excludes superseded snapshot rows (roughly 40%
  of the view).

The view also exposes pre-computed location fields
(`home_local_division_name`, `home_city_name`, `home_postal_code_name`) which
the queries use directly rather than running spatial joins.

## Layout

```
.
├── pipeline/                            Python package (the orchestrator)
│   ├── cli.py                           argparse + entry point
│   ├── database.py                      SQLAlchemy wrapper + omni-view helpers
│   ├── mapping.py                       Query list (SQL file -> output CSV)
│   ├── output.py                        Output-directory creation, CSV writes
│   ├── postprocess.py                   Data transformations/manipulation the required by visualization tooling
│   ├── publish_infogram.py              Per-county PDF publisher (Infogram REST API)
│   ├── render_bubbles.py                Incident-history bubble-plot renderer
│   ├── render_days_waiting.py           Polar histogram of days-to-close
│   ├── render_proportional_legend.py    Gradient legend for the proportional-area chart
│   ├── prepare_heatmap.py               Convert area-code heatmap WKB to WKT for Kepler.gl
│   ├── prepare_volunteer_locations.py   Convert volunteer-location WKB to WKT for Kepler.gl
│   ├── svi_classification.py            Trend classification of the SVI completion distribution
│   ├── runner.py                        Top-level pipeline runner
│   └── substitution.py                  SQL parameter substitution
└── sql/                          SQL templates, one file per query
    ├── incident_overview/
    ├── state_summary/
    ├── county_summary/
    ├── hotline/
    ├── stats/
    ├── general/
    └── marketing/
```

## Execution

The pipeline expects a PostgreSQL connection to the Crisis Cleanup
operational database. The analytics view
(`r.cases_new_claimed_closed_omni_mag`) and its refresh procedure must be
available on that database.

### Docker (recommended)

```bash
docker build -t magazine-orchestrator .

docker run --rm \
    -v ~/magazine_output:/mnt/data \
    magazine-orchestrator \
    --incident-ids "$INCIDENT_ID" \
    --label "$ISSUE_NUMBER" \
    --db-host  "$DB_HOST" \
    --db-port  "5432" \
    --db-user  "postgres" \
    --db-password "$DB_PASSWORD" \
    --incident-type "$INCIDENT_TYPE" \
    --state-list "$STATE_LIST"
```

Outputs are written to `~/magazine_output/report_${INCIDENT_ID}_${ISSUE_NUMBER}/`.

### Local Python

```bash
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt

python -m pipeline \
    --incident-ids "$INCIDENT_ID" \
    --label "$ISSUE_NUMBER" \
    --output-path ./output \
    --db-host "$DB_HOST" \
    --db-user "postgres" \
    --db-password "$DB_PASSWORD" \
    --incident-type "$INCIDENT_TYPE" \
    --state-list "$STATE_LIST"
```

## Arguments

| Argument | Required | Description |
| --- | --- | --- |
| `--incident-ids` | yes | Comma-separated incident IDs (e.g. `"185"` or `"175,172,180"`). |
| `--label` | no | Label appended to the output directory. Defaults to today's date. |
| `--output-path` | no | Root for output directories. Defaults to `/mnt/data`. |
| `--db-host`, `--db-user`, `--db-password` | yes | Connection details. |
| `--db-port`, `--db-name` | no | Default to `5432` and `crisiscleanup`. |
| `--incident-type` | no | Used by `stats/front_cover.sql` to group "incidents of this type". |
| `--state-list` | no | Two-letter state codes for state-level and county-level outputs. |
| `--refresh` | no | `incremental` or `full` -- triggers the analytics-view refresh stored procedure before running. |
| `--check-freshness` | no | Refuses to run if the view is more than 24 hours stale. |
| `--skip-freshness-check` | no | Runs even if the view is stale. |

## Output

```
report_185_issue_7/
├── incident_overview/
│   ├── 1_incident_history.csv
│   ├── 2_orgs_timeline.csv
│   ├── 2_calls_timeline.csv
│   ├── 3_bubble_plot.csv
│   ├── 5_worktype_donut.csv
│   ├── 6_cases_by_status.csv         # cumulative
│   ├── 7_worktype_closures.csv       # cumulative, one column per work type
│   ├── 8_volunteer_engagement.csv
│   ├── 9_daily_active_organizations.csv
│   ├── 10_commercial_value_of_services.csv
│   ├── 11_cases_by_worktype.csv
│   ├── 12_needs_met_svi.csv
│   ├── 13_commercial_value_svi.csv
│   ├── days_waiting_for_service.csv
│   ├── proportional_area_chart.csv
│   └── donut_plots/                  # one CSV per work type + captions
├── state_summary/
│   └── {STATE}_*.csv                 # six files per state
├── county_summary/
│   └── {STATE}_commercial_value.csv  # one row per county+work_type, fed to publish_infogram
├── hotline/
│   ├── 4_hotline_map.csv
│   ├── 4_volunteer_locations_map.csv
│   ├── hotline_calls.csv
│   └── supporting_*.csv
├── stats/
│   └── supporting_*.csv              # front cover, history, hotline, service, ...
├── general/
│   └── supporting_*.csv              # back cover, phone volunteers
├── marketing/
│   └── supporting_*.csv
└── run_report.json
```

## Execution Flow

1. **Connect.** The database driver is set up and a `SELECT 1` confirms the
   connection.
2. **(Optional) refresh.** If `--refresh` was passed, the analytics-view
   stored procedure is invoked for the requested incidents.
3. **(Optional) freshness check.** Unless `--skip-freshness-check` was set,
   the pipeline confirms the view has data for every incident and that the
   most recent `updated_at` is within 24 hours.
4. **Analysis window.** The min/max `the_date` flagged
   `is_within_analysis = true` is logged.
5. **Output directory** is created.
6. **Incident queries** -- the main visualization queries run in sequence.
   Each result is saved as its own CSV.
7. **State queries** -- for every state in `--state-list`, the seven
   state-level queries run and write `{STATE}_*.csv`.
8. **County queries** -- per state, produces `county_summary/{STATE}_commercial_value.csv`
   for use by the Infogram publisher (see below).
9. **Supporting queries** -- single-statement stats/sidebar queries.
10. **Post-processing** -- cumulative sums, date relabelling, SVI bucket fill,
    work-type splitting, donut generation.
11. **Audit log** -- `run_report.json` records every file written, every
    failure, row counts, and the analysis window.

## Extracting Per-County from Infogram

The county-summary section of the magazine has one chart per county/area, so
manual upload would be tedious. ``pipeline/publish_infogram.py`` reads the
``commercial_value.csv`` produced by the pipeline and, for each unique
county, pushes the data into a chart in an Infogram project and downloads the
resulting PDF.

Credentials and identifiers are read from the environment:

| Variable | Purpose |
| --- | --- |
| `INFOGRAM_API_KEY`    | Bearer token for the Infogram REST API. |
| `INFOGRAM_PROJECT_ID` | UUID of the project that contains the chart template. |
| `INFOGRAM_ELEMENT_ID` | ID of the chart element to overwrite within that project. |

```bash
export INFOGRAM_API_KEY=...
export INFOGRAM_PROJECT_ID=...
export INFOGRAM_ELEMENT_ID=...

python -m pipeline.publish_infogram \
    --input  ./output/report_${INCIDENT_ID}_${ISSUE_NUMBER}/county_summary/MO_commercial_value.csv \
    --output-dir ./output/report_${INCIDENT_ID}_${ISSUE_NUMBER}/county_pdfs
```

For each unique value of `name` in the input CSV the publisher:

1. Calls `POST https://api.infogram.com/updateProjectEntities` to replace the
   data table backing the chart element with that county's work-type
   breakdown (Closed / Claimed / Open Unclaimed across Trees, Debris, Muck
   Out, Fence, Tarp, Other).
2. Calls `POST https://api.infogram.com/downloadProject` to enqueue a PDF
   export of the project.
3. Subscribes to `GET https://api.infogram.com/getTaskStatus?taskId=…` via
   Server-Sent Events and waits for the export task to reach 100 %.
4. Downloads the PDF and writes it to
   `{location_id}_{county_name}_value.pdf` in the chosen output directory.

## Additional Chart Rendering and Kepler.gl for Mapping

Several magazine assets are produced by rendering matplotlib charts directly,
or by reshaping pipeline output for an external map tool. Each is a standalone
CLI module that consumes a CSV the pipeline has already produced.

| Module | Reads | Produces |
| --- | --- | --- |
| `pipeline.render_bubbles` | `incident_overview/3_bubble_plot.csv` | One PDF per `(incident_type, year)` -- the incident-history bubble plots. |
| `pipeline.render_days_waiting` | `incident_overview/days_waiting_for_service.csv` | A polar-histogram PNG of cases closed N days after they were reported. |
| `pipeline.render_proportional_legend` | (no input) | The gradient colour-bar PNG shown next to the proportional-area chart. |
| `pipeline.prepare_heatmap` | `hotline/4_hotline_map.csv` | A Kepler.gl-friendly CSV with WKT geometry and a log-scaled call-volume column. |
| `pipeline.prepare_volunteer_locations` | `hotline/4_volunteer_locations_map.csv` | A Kepler.gl-friendly CSV with point geometry as WKT. |
| `pipeline.svi_classification` | `incident_overview/12_needs_met_svi.csv` (or a state variant) | A one-row CSV with the trend classification ("more vulnerable communities helped more", etc.) and the fitted slope. |

Each accepts `--help` for its full argument list. Example:

```bash
RUN_DIR=./output/report_${INCIDENT_ID}_${ISSUE_NUMBER}

python -m pipeline.render_bubbles \
    --input "$RUN_DIR/incident_overview/3_bubble_plot.csv" \
    --output-dir "$RUN_DIR/bubble_plots"

python -m pipeline.render_days_waiting \
    --input  "$RUN_DIR/incident_overview/days_waiting_for_service.csv" \
    --output "$RUN_DIR/days_waiting.png"

python -m pipeline.render_proportional_legend \
    --output "$RUN_DIR/proportional_legend.png"

python -m pipeline.prepare_heatmap \
    --input  "$RUN_DIR/hotline/4_hotline_map.csv" \
    --output "$RUN_DIR/hotline/4_hotline_map_kepler.csv"

python -m pipeline.prepare_volunteer_locations \
    --input  "$RUN_DIR/hotline/4_volunteer_locations_map.csv" \
    --output "$RUN_DIR/hotline/4_volunteer_locations_kepler.csv"

python -m pipeline.svi_classification \
    --input  "$RUN_DIR/incident_overview/12_needs_met_svi.csv" \
    --output "$RUN_DIR/incident_overview/svi_classification.csv"
```

## SQL Templates

Each SQL file is a self-contained query. Three placeholders are substituted
at runtime:

- The sentinel array `string_to_array('175', ',')::int[]` becomes
  `string_to_array('<your ids>', ',')::int[]`. Every reference is replaced
  consistently so a single file can target multiple incidents.
- `STATE_PLACEHOLDER` becomes the two-letter state code in state-level
  queries. When no state is supplied, lines mentioning it are dropped so the
  query collapses back to its unfiltered form.
- `STATE_LIST_PLACEHOLDER` and `INCIDENT_TYPE_PLACEHOLDER` are filled by the
  front-cover query and a couple of others. When no value is supplied, the
  quoted placeholder is replaced with `NULL`.

To add a new query: drop the SQL file into the matching `sql/` subdirectory,
add an entry to `pipeline/mapping.py`, and (if it needs custom shaping) add a
handler in `pipeline/postprocess.py`.

## SQL Conventions

A few patterns recur across the queries. They exist for specific reasons
and are worth noting for posterity:

- **Always filter `invalidated_at IS NULL`.** Roughly 40% of rows in the
  analytics view are superseded snapshots. Forgetting this filter inflates
  every count.
- **Two-stage aggregation.** The view is at work-type granularity (one row
  per work type per snapshot). To count *cases* (worksites) correctly,
  queries aggregate work types into worksites first, then aggregate
  worksites into the final metric.
- **Ratio-based counting.** When a worksite has four work types and two are
  closed, that contributes `0.5` to the closed-case count rather than `2`.
  This is why the case counts in the output are fractional.
- **`DISTINCT ON` rather than `is_daily_last`.** The "last snapshot of the
  day" flag is unreliable, so queries use
  `DISTINCT ON (worksite_id, work_type_key) ORDER BY the_date DESC` to pick
  the latest snapshot deterministically.
- **State filtering uses `RIGHT(COALESCE(home_local_division_name,
  home_city_name), 2)`.** Falling back to the city name means independent
  cities (e.g. St. Louis City) are correctly included rather than missed by
  a county-only filter.

## Requirements

- Python 3.11+
- PostgreSQL with the `r.cases_new_claimed_closed_omni_mag` materialised view
  and its refresh procedure available
- `pandas`, `SQLAlchemy`, `psycopg2-binary` (see `requirements.txt`)
