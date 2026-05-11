"""Render the bubble plots for the incident-history section of the magazine.

The bubble plot shows historical incidents on a (year, intensity) grid. For
each incident type and each year, two concentric circles are drawn -- a
white outer circle sized by ``total_cases`` and a coloured inner circle
sized by ``closed_cases`` -- with a small caption beside each point and a
completion-percentage label inside larger ones.

Input columns (produced by ``sql/incident_overview/incident_bubbles.sql``):

* ``x_axis``           -- year for the x position
* ``y_axis``           -- magnitude/intensity for the y position
* ``total_cases``      -- bubble outer size
* ``closed_cases``     -- bubble inner size
* ``incident_type``    -- used to split outputs into groups
* ``incident_short_name``  -- short name used in the caption
* ``start_date``       -- used to bucket plots by year
"""

from __future__ import annotations

import argparse
import logging
import sys
from dataclasses import dataclass
from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np
import pandas as pd
from matplotlib.lines import Line2D


logger = logging.getLogger(__name__)


REQUIRED_COLUMNS = (
    "x_axis", "y_axis", "total_cases", "closed_cases",
    "incident_type", "incident_short_name", "start_date",
)


@dataclass(frozen=True)
class Style:
    background:        str = "#b7d8e9"
    total_face:        str = "#ffffff"
    total_edge:        str = "#4e4e4e"
    closed_face:       str = "#578b94"
    figsize_inches:    tuple[float, float] = (10.0, 10.0)
    label_font_size:   int = 12
    title_font_size:   int = 14
    legend_font_size:  int = 12
    tick_font_size:    int = 14
    scale_factor:      float = 8.0
    label_offset:      float = 0.14
    # Only show the percentage label inside bubbles whose total exceeds this
    # percentile of the dataset (suppresses clutter from tiny bubbles).
    pct_label_percentile: float = 50.0


def _format_total(total: float) -> str:
    return f"{total / 1000:.1f}k" if total >= 1000 else f"{int(total)}"


def _summary(row: pd.Series) -> str:
    pct = 0
    if row["total_cases"]:
        pct = int(round(row["closed_cases"] / row["total_cases"] * 100))
    return f"{row['incident_short_name']}\n{pct}% of {_format_total(row['total_cases'])}"


def _plot_group(
    df: pd.DataFrame,
    title: str,
    year: int,
    y_min: float,
    y_max: float,
    threshold: float,
    style: Style,
    output_path: Path,
) -> None:
    valid_years = sorted(df["x_axis"].dropna().unique())
    year_to_x = {y: i for i, y in enumerate(valid_years)}

    x = df["x_axis"].map(year_to_x)
    y = df["y_axis"]
    totals = df["total_cases"]
    closed = df["closed_cases"]
    summaries = df["incident_summary"]

    pct_closed = np.where(totals > 0, (closed / totals) * 100, np.nan)

    fig, ax = plt.subplots(figsize=style.figsize_inches)
    fig.patch.set_facecolor(style.background)
    ax.set_facecolor(style.background)

    ax.scatter(
        x, y,
        s=totals * style.scale_factor,
        color=style.total_face, edgecolors=style.total_edge,
        linewidth=0.8, alpha=0.7, label="Total Cases",
    )
    ax.scatter(
        x, y,
        s=closed * style.scale_factor,
        color=style.closed_face, label="Closed Cases",
    )

    for i in range(len(df)):
        if totals.iloc[i] > threshold:
            ax.text(
                x.iloc[i] + style.label_offset,
                y.iloc[i],
                summaries.iloc[i],
                fontsize=style.label_font_size,
                color="black",
                alpha=0.8,
            )
            if pd.notna(pct_closed[i]):
                ax.text(
                    x.iloc[i], y.iloc[i],
                    f"{round(pct_closed[i]):.0f}%",
                    fontsize=style.label_font_size,
                    color="white", alpha=0.9,
                    ha="center", va="center",
                )

    ax.set_title(f"{title} - {year}", fontsize=style.title_font_size)
    ax.set_xticks(range(len(valid_years)))
    ax.set_xticklabels(valid_years, fontsize=style.tick_font_size)
    ax.set_ylim(y_min - 63, y_max + 80)
    ax.set_xlim(-0.5, len(valid_years) - 0.5 + style.label_offset)

    for spine in ax.spines.values():
        spine.set_visible(False)

    handles = [
        Line2D([0], [0], marker="o", color="w",
               markerfacecolor=style.total_face, markeredgecolor=style.total_edge,
               markersize=18, linewidth=0.5, label="Total Cases"),
        Line2D([0], [0], marker="o", color="w",
               markerfacecolor=style.closed_face,
               markersize=18, label="Closed Cases"),
    ]
    legend = ax.legend(handles=handles, loc="upper right",
                       fontsize=style.legend_font_size, frameon=False)
    legend.get_frame().set_facecolor(style.background)

    plt.savefig(output_path, dpi=300, bbox_inches="tight", format="pdf")
    plt.close()
    logger.info("Saved %s", output_path)


def render(csv_path: Path, output_dir: Path, style: Style) -> None:
    df = pd.read_csv(csv_path)
    missing = [c for c in REQUIRED_COLUMNS if c not in df.columns]
    if missing:
        raise SystemExit(f"Input CSV is missing required columns: {missing}")

    df = df.copy()
    df["start_date"] = pd.to_datetime(df["start_date"], errors="coerce")
    df["incident_summary"] = df.apply(_summary, axis=1)

    output_dir.mkdir(parents=True, exist_ok=True)

    # One PDF per (incident_type, year). Group together so the y-axis scale
    # and percentile thresholds stay consistent within a category.
    for incident_type, type_df in df.groupby("incident_type"):
        y_min = float(type_df["y_axis"].min())
        y_max = float(type_df["y_axis"].max())
        totals = type_df["total_cases"].dropna()
        if totals.empty:
            continue
        threshold = float(np.percentile(totals, style.pct_label_percentile))

        for year in sorted(type_df["start_date"].dt.year.dropna().unique()):
            year_df = type_df[type_df["start_date"].dt.year == year]
            if year_df.empty:
                continue
            title = str(incident_type).replace("_", " ").title()
            safe_title = title.replace(" ", "_")
            output_path = output_dir / f"{safe_title}_{int(year)}_bubble_plot.pdf"
            _plot_group(year_df, title, int(year), y_min, y_max, threshold, style, output_path)


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="pipeline.render_bubbles",
        description="Render incident-history bubble-plot PDFs.",
    )
    parser.add_argument("--input", required=True, type=Path,
                        help="Path to 3_bubble_plot.csv produced by the pipeline.")
    parser.add_argument("--output-dir", required=True, type=Path,
                        help="Directory where PDF files will be written.")
    parser.add_argument("--background", default=Style.background)
    parser.add_argument("--closed-color", default=Style.closed_face)
    parser.add_argument("--scale-factor", type=float, default=Style.scale_factor,
                        help="Multiplier applied to total/closed counts when sizing bubbles.")
    parser.add_argument("--label-offset", type=float, default=Style.label_offset,
                        help="Horizontal offset for caption text (relative to year index).")
    parser.add_argument("--label-percentile", type=float, default=Style.pct_label_percentile,
                        help="Suppress labels for bubbles below this total-cases percentile.")
    return parser.parse_args()


def main() -> None:
    args = _parse_args()
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)-7s %(message)s")
    style = Style(
        background=args.background,
        closed_face=args.closed_color,
        scale_factor=args.scale_factor,
        label_offset=args.label_offset,
        pct_label_percentile=args.label_percentile,
    )
    render(args.input, args.output_dir, style)


if __name__ == "__main__":
    main()
