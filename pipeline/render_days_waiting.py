"""Render the polar histogram of days-to-close for the magazine.

The chart shows a circular histogram where each sector is one day (0-N) and
sector height is the number of worksites closed that many days after they
were reported.

Input columns (produced by ``sql/incident_overview/days_waiting_for_service.sql``):

* ``day``   -- integer, days from request to closure
* ``count`` -- integer, number of worksites in that bucket
"""

from __future__ import annotations

import argparse
import logging
from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np
import pandas as pd


logger = logging.getLogger(__name__)


def render(
    csv_path: Path,
    output_path: Path,
    *,
    max_days: int,
    color: str,
    even_labels_only: bool,
    boost_day_zero: bool,
) -> None:
    df = pd.read_csv(csv_path)
    if "day" not in df.columns or "count" not in df.columns:
        raise SystemExit("Input CSV must include 'day' and 'count' columns")

    # Build a dense count vector for every day in [0, max_days).
    counts = np.zeros(max_days, dtype=int)
    for _, row in df.iterrows():
        d = int(row["day"])
        if 0 <= d < max_days:
            counts[d] = int(row["count"])

    # Day-0 is normally orders of magnitude larger than every other bucket
    # (most cases close the same day they are reported), which squashes the
    # rest of the chart. Render the rest of the day-0 sector at a visually
    # comparable height while preserving the true max for the label.
    true_max = int(counts.max()) if counts.size else 0
    if boost_day_zero and counts.size > 1:
        second_max = int(np.partition(counts, -2)[-2])
        if second_max > 0:
            counts[0] = int(second_max * 1.1)

    theta = np.linspace(np.pi / 2, -2 * np.pi + np.pi / 2, max_days, endpoint=False)
    width = (np.pi / (max_days / 2)) * np.ones_like(counts, dtype=float)

    fig, ax = plt.subplots(subplot_kw={"projection": "polar"}, figsize=(8, 8))
    ax.bar(theta, counts, width=width, bottom=0.0, color=color)

    # Day labels around the outside of the circle.
    label_offset = 1.115
    radius_max = counts.max() if counts.max() > 0 else 1
    for i in range(max_days):
        if even_labels_only and i % 2:
            continue
        ax.text(
            theta[i], radius_max * label_offset, str(i),
            ha="center", va="center", fontsize=10,
        )
        ax.plot([theta[i], theta[i]], [0, radius_max], color="gray", linewidth=0.5, linestyle="--")

    # Concentric reference rings rounded to the nearest 100.
    num_rings = 5
    levels = np.linspace(0, radius_max, num_rings + 1)
    rounded_levels = np.round(levels / 100) * 100
    for level in levels:
        ax.plot(np.linspace(0, 2 * np.pi, 100), np.full(100, level),
                color="gray", linewidth=0.5, linestyle="--")
    for level in rounded_levels[:-1]:
        ax.text(np.pi, level + 0.5, f"{int(level):,}",
                ha="center", va="center", fontsize=10, color="gray", rotation=90)

    # Final outer ring label uses the true maximum, rounded to the nearest 100.
    outer_label = int(round(true_max, -2))
    ax.text(np.pi, levels[-1] + 0.5, f"{outer_label:,}",
            ha="center", va="center", fontsize=10, color="gray", rotation=90)

    ax.grid(False)
    ax.set_yticklabels([])
    ax.set_xticklabels([])

    output_path.parent.mkdir(parents=True, exist_ok=True)
    plt.savefig(output_path, format="png", dpi=300, bbox_inches="tight")
    plt.close()
    logger.info("Saved %s", output_path)


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="pipeline.render_days_waiting",
        description="Render the polar 'days waiting for service' histogram.",
    )
    parser.add_argument("--input", required=True, type=Path,
                        help="Path to days_waiting_for_service.csv produced by the pipeline.")
    parser.add_argument("--output", required=True, type=Path,
                        help="Output PNG path.")
    parser.add_argument("--max-days", type=int, default=60,
                        help="Number of sectors in the histogram (default: 60).")
    parser.add_argument("--color", default="#6D396A",
                        help="Bar colour (default: #6D396A).")
    parser.add_argument("--all-labels", action="store_true",
                        help="Show every day label instead of every other one.")
    parser.add_argument("--no-boost-day-zero", action="store_true",
                        help="Render the true day-0 count instead of capping it visually.")
    return parser.parse_args()


def main() -> None:
    args = _parse_args()
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)-7s %(message)s")
    render(
        args.input,
        args.output,
        max_days=args.max_days,
        color=args.color,
        even_labels_only=not args.all_labels,
        boost_day_zero=not args.no_boost_day_zero,
    )


if __name__ == "__main__":
    main()
