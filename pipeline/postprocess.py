"""Post-processing CSV transformations.

The SQL output is the raw shape of the data. The downstream visualisation tool
(Infogram) expects each CSV in a very particular form -- cumulative sums,
specific column names, alternating date labels, complete SVI buckets, and so
on. These transformations are applied after every run.
"""

from __future__ import annotations

import logging
from pathlib import Path

import pandas as pd


logger = logging.getLogger(__name__)


# Work types we exclude from the magazine outputs (they are tracked in the
# system but are not part of the published case-progress story).
EXCLUDED_WORK_TYPES = ("mold_remediation", "rebuild", "shopping", "report")


# The ten Social Vulnerability Index buckets (0.0-0.1 through 0.9-1.0). Outputs
# must always contain every bucket so the chart has a stable x-axis.
SVI_BUCKETS = tuple(
    f"{i / 10:.1f}".rjust(3, "0") + " - " + f"{(i + 1) / 10:.1f}".rjust(3, "0")
    for i in range(10)
)


# --------------------------------------------------------------------------- #
# helpers                                                                     #
# --------------------------------------------------------------------------- #


def _alternate_dates(dates: pd.Series) -> list[str]:
    """Render every second date as ``"Mon d"`` and leave the rest blank.

    Infogram's date axis prints labels too densely otherwise.
    """
    out: list[str] = []
    for i, value in enumerate(dates):
        if i % 2 or pd.isna(value):
            out.append("")
            continue
        dt = pd.to_datetime(value)
        out.append(f"{dt.strftime('%b')} {dt.day}")
    return out


def _cumulative_by_date(df: pd.DataFrame, value_cols: list[str]) -> pd.DataFrame:
    """Group by date, fill missing days, and take the running total."""
    df["creation_date"] = pd.to_datetime(df["creation_date"])
    df = df.groupby("creation_date", as_index=False)[value_cols].sum()
    df = df.sort_values("creation_date")
    full_range = pd.date_range(df["creation_date"].min(), df["creation_date"].max(), freq="D")
    df = pd.DataFrame({"creation_date": full_range}).merge(df, on="creation_date", how="left").fillna(0)
    for col in value_cols:
        df[col] = df[col].cumsum()
    return df


def _alternate_dates_in_place(path: Path) -> None:
    """Apply the alternating-date label to ``creation_date`` if the column exists."""
    if not path.exists():
        return
    df = pd.read_csv(path)
    if "creation_date" not in df.columns:
        return
    df["creation_date"] = _alternate_dates(pd.to_datetime(df["creation_date"]))
    df.to_csv(path, index=False)
    logger.info("Updated date labels in %s", path.name)


def _floats_to_int(path: Path, column: str) -> None:
    """Strip the trailing ``.0`` from a numeric column."""
    if not path.exists():
        return
    df = pd.read_csv(path)
    if column in df.columns:
        df[column] = df[column].astype(int)
        df.to_csv(path, index=False)
        logger.info("Converted %s in %s to int", column, path.name)


def _fill_svi_buckets(path: Path, value_cols: dict[str, object]) -> None:
    """Insert any missing SVI bucket rows with sensible defaults.

    ``value_cols`` maps column name to the default value used when a bucket is
    absent in the input (e.g. ``{"percentage": "0%"}`` or ``{"closed_value": 0}``).
    """
    if not path.exists():
        return
    df = pd.read_csv(path)
    required = {"svi_bin", *value_cols.keys()}
    missing = required - set(df.columns)
    if missing:
        logger.error("SVI file %s is missing columns %s", path.name, missing)
        return
    complete = pd.DataFrame({"svi_bin": list(SVI_BUCKETS)})
    merged = complete.merge(df, on="svi_bin", how="left")
    for col, default in value_cols.items():
        merged[col] = merged[col].fillna(default)
    merged = merged.sort_values("svi_bin", ascending=False)
    merged.to_csv(path, index=False)
    logger.info("Filled SVI buckets in %s (%d rows)", path.name, len(merged))


# --------------------------------------------------------------------------- #
# incident-level                                                              #
# --------------------------------------------------------------------------- #


def _cases_by_status(run_dir: Path) -> None:
    """Convert daily-new cases into a cumulative chart."""
    path = run_dir / "incident_overview" / "6_cases_by_status.csv"
    if not path.exists():
        return

    raw = pd.read_csv(path)
    df = _cumulative_by_date(
        raw,
        [
            "closed_commercial_value",
            "open_claimed_value",
            "open_unclaimed_value",
            "Closed",
            "Open Claimed",
            "Open Unclaimed",
        ],
    )

    cases = df[["creation_date", "Closed", "Open Claimed", "Open Unclaimed"]].copy()
    cases["creation_date"] = _alternate_dates(cases["creation_date"])
    cases.to_csv(path, index=False)
    logger.info("Wrote cumulative cases-by-status to %s", path.name)

    # Companion reference files used by the design team.
    cases.to_csv(path.parent / "incident_timeseries_cases.csv", index=False)

    values = df[["creation_date", "closed_commercial_value", "open_claimed_value", "open_unclaimed_value"]].copy()
    values.columns = ["creation_date", "Closed", "Open Claimed", "Open Unclaimed"]
    values["creation_date"] = _alternate_dates(values["creation_date"])
    values.to_csv(path.parent / "incident_timeseries_value.csv", index=False)


def _worktype_closures(run_dir: Path) -> None:
    """Cumulative work-type closures, pivoted into one column per work type."""
    path = run_dir / "incident_overview" / "7_worktype_closures.csv"
    if not path.exists():
        return

    df = pd.read_csv(path)
    df["creation_date"] = pd.to_datetime(df["creation_date"])
    df = df[~df["work_type_key"].isin(EXCLUDED_WORK_TYPES)]

    grouped = df.groupby(["creation_date", "work_type_key"], as_index=False)["closed_cases"].sum()
    full_range = pd.date_range(df["creation_date"].min(), df["creation_date"].max(), freq="D")
    pivot = grouped.pivot(index="creation_date", columns="work_type_key", values="closed_cases").fillna(0)

    out = pd.DataFrame({"creation_date": full_range}).merge(pivot, on="creation_date", how="left").fillna(0)
    work_type_cols = [c for c in out.columns if c != "creation_date"]
    for col in work_type_cols:
        out[col] = out[col].cumsum()

    out.columns = ["creation_date"] + [c.replace("_", " ").title() for c in work_type_cols]
    out["creation_date"] = _alternate_dates(out["creation_date"])
    out.to_csv(path, index=False)
    logger.info("Wrote cumulative work-type closures to %s", path.name)

    out.to_csv(path.parent / "incident_worktype_timeseries_cases.csv", index=False)


def _commercial_value_of_services(run_dir: Path) -> None:
    """Swap case-count columns for the matching commercial-value columns."""
    path = run_dir / "incident_overview" / "10_commercial_value_of_services.csv"
    if not path.exists():
        return
    df = pd.read_csv(path)
    needed = ["closed_commercial_value", "open_claimed_commercial_value", "open_unclaimed_commercial_value"]
    if not all(col in df.columns for col in needed):
        return
    out = pd.DataFrame(
        {
            "work_type_key": df["work_type_key"],
            "Closed":          df["closed_commercial_value"],
            "Open Claimed":    df["open_claimed_commercial_value"],
            "Open Unclaimed":  df["open_unclaimed_commercial_value"],
        }
    )
    out.to_csv(path, index=False)
    logger.info("Rewrote %s using commercial values", path.name)


def _cases_by_worktype(run_dir: Path) -> None:
    """Drop the commercial-value columns, keep only the case counts."""
    path = run_dir / "incident_overview" / "11_cases_by_worktype.csv"
    if not path.exists():
        return
    df = pd.read_csv(path)
    keep = ["work_type_key", "Closed", "Open Claimed", "Open Unclaimed"]
    if all(col in df.columns for col in keep):
        df[keep].to_csv(path, index=False)
        logger.info("Trimmed %s to case-count columns", path.name)


def _donut_plots(run_dir: Path) -> None:
    """Write one donut-chart CSV per work type, plus a captions index."""
    source = run_dir / "incident_overview" / "5_worktype_donut.csv"
    if not source.exists():
        return
    df = pd.read_csv(source)
    out_dir = run_dir / "incident_overview" / "donut_plots"
    out_dir.mkdir(exist_ok=True)

    captions: list[dict[str, str]] = []
    for key in df["work_type_key"].unique():
        if key in EXCLUDED_WORK_TYPES:
            continue
        slice_df = df[df["work_type_key"].str.lower() == key.lower()]
        if slice_df.empty:
            continue
        label = key.replace("_", " ").title()
        closed     = slice_df["Closed"].sum()
        claimed    = slice_df["Open Claimed"].sum()
        unclaimed  = slice_df["Open Unclaimed"].sum()
        total      = closed + claimed + unclaimed

        donut = pd.DataFrame(
            {
                "type":  ["Closed", "Open Claimed", "Open Unclaimed"],
                label:   [closed, claimed, unclaimed],
            }
        )
        donut.to_csv(out_dir / f"{label}_donut_plot.csv", index=False)

        pct = (closed / total * 100) if total > 0 else 0
        captions.append({"work_type_key": label, "caption": f"{int(total)} Cases {pct:.0f}% complete"})

    if captions:
        pd.DataFrame(captions).to_csv(out_dir / "donut_captions.csv", index=False)
        logger.info("Wrote %d donut plots", len(captions))


# --------------------------------------------------------------------------- #
# state-level                                                                 #
# --------------------------------------------------------------------------- #


def _state_cases_by_status(path: Path) -> None:
    df = pd.read_csv(path)
    if "creation_date" not in df.columns:
        return
    df["creation_date"] = pd.to_datetime(df["creation_date"])
    df = df.sort_values("creation_date")
    for col in [c for c in df.columns if c != "creation_date"]:
        df[col] = df[col].cumsum()
    df["creation_date"] = _alternate_dates(df["creation_date"])
    keep = ["creation_date", "Closed", "Open Claimed", "Open Unclaimed"]
    if all(col in df.columns for col in keep):
        df = df[keep]
    df.to_csv(path, index=False)
    logger.info("Updated %s with cumulative values", path.name)


def _state_worktype_closures(path: Path) -> None:
    df = pd.read_csv(path)
    if "creation_date" not in df.columns or "work_type_key" not in df.columns:
        return
    df["creation_date"] = pd.to_datetime(df["creation_date"])
    df = df[~df["work_type_key"].isin(EXCLUDED_WORK_TYPES)]

    grouped = df.groupby(["creation_date", "work_type_key"], as_index=False)["closed_cases"].sum()
    full_range = pd.date_range(df["creation_date"].min(), df["creation_date"].max(), freq="D")
    pivot = grouped.pivot(index="creation_date", columns="work_type_key", values="closed_cases").fillna(0)

    out = pd.DataFrame({"creation_date": full_range}).merge(pivot, on="creation_date", how="left").fillna(0)
    work_type_cols = [c for c in out.columns if c != "creation_date"]
    for col in work_type_cols:
        out[col] = out[col].cumsum()

    out.columns = ["creation_date"] + [c.replace("_", " ").title() for c in work_type_cols]
    out["creation_date"] = _alternate_dates(out["creation_date"])
    out.to_csv(path, index=False)
    logger.info("Updated state worktype closures: %s", path.name)


# Map a state-level CSV name to the handler that knows how to transform it.
_STATE_HANDLERS = {
    "6_cases_by_status.csv":            _state_cases_by_status,
    "7_worktype_closures.csv":          _state_worktype_closures,
    "9_daily_active_organizations.csv": lambda p: _alternate_dates_in_place(p),
    "11_cases_by_worktype.csv":         lambda p: _cases_by_worktype_keep_counts(p),
    "12_needs_met_svi.csv":             lambda p: _fill_svi_buckets(p, {"percentage": "0%"}),
    "13_commercial_value_svi.csv":      lambda p: _fill_svi_buckets(
        p,
        {"closed_value": 0, "open_claimed_value": 0, "open_unclaimed_value": 0},
    ),
}


def _cases_by_worktype_keep_counts(path: Path) -> None:
    """State variant of :func:`_cases_by_worktype`."""
    df = pd.read_csv(path)
    keep = ["work_type_key", "Closed", "Open Claimed", "Open Unclaimed"]
    if all(col in df.columns for col in keep):
        df[keep].to_csv(path, index=False)


def _apply_state_postprocess(run_dir: Path) -> None:
    """Apply each state-level handler to every matching ``<STATE>_*`` file."""
    state_dir = run_dir / "state_summary"
    if not state_dir.exists():
        return
    for path in state_dir.glob("*_*.csv"):
        # Filenames look like ``MO_6_cases_by_status.csv`` -- strip the state code.
        try:
            _, suffix = path.name.split("_", 1)
        except ValueError:
            continue
        handler = _STATE_HANDLERS.get(suffix)
        if handler is None:
            continue
        try:
            handler(path)
        except Exception as exc:
            logger.error("Failed to post-process %s: %s", path, exc)


# --------------------------------------------------------------------------- #
# entry point                                                                 #
# --------------------------------------------------------------------------- #


def run(run_dir: Path) -> None:
    """Apply every post-processing step to ``run_dir``."""
    incident_dir = run_dir / "incident_overview"
    hotline_dir = run_dir / "hotline"

    _cases_by_status(run_dir)
    _worktype_closures(run_dir)
    _commercial_value_of_services(run_dir)
    _cases_by_worktype(run_dir)

    _alternate_dates_in_place(incident_dir / "9_daily_active_organizations.csv")
    _alternate_dates_in_place(incident_dir / "8_volunteer_engagement.csv")
    _alternate_dates_in_place(hotline_dir / "hotline_calls.csv")

    _floats_to_int(incident_dir / "2_orgs_timeline.csv",  "year")
    _floats_to_int(incident_dir / "2_calls_timeline.csv", "year")
    _floats_to_int(incident_dir / "3_bubble_plot.csv",    "x_axis")

    _fill_svi_buckets(incident_dir / "12_needs_met_svi.csv",     {"percentage": "0%"})
    _fill_svi_buckets(
        incident_dir / "13_commercial_value_svi.csv",
        {"closed_value": 0, "open_claimed_value": 0, "open_unclaimed_value": 0},
    )

    _apply_state_postprocess(run_dir)
    _donut_plots(run_dir)
