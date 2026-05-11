"""Classify the SVI completion distribution into a one-line natural-language insight.

Fits a least-squares line to the per-bucket completion percentages and
produces a short caption describing whether more or less vulnerable
communities were helped disproportionately. The pipeline's main SVI CSVs
already contain the per-bucket percentages -- this module derives the
trend from them.

Input columns (produced by ``sql/incident_overview/svi_help.sql`` or its
state-summary equivalent):

* ``svi_bin``    -- bucket label, e.g. ``"0.4 - 0.5"``
* ``percentage`` -- string like ``"42%"`` or numeric percentage
"""

from __future__ import annotations

import argparse
import logging
import re
from pathlib import Path

import numpy as np
import pandas as pd


logger = logging.getLogger(__name__)


# Slope threshold (percentage points per bucket) beyond which the
# distribution is considered to favour one end of the SVI scale.
SLOPE_THRESHOLD = 2.0


CLASSIFICATIONS = {
    "less_vulnerable":
        "Less vulnerable communities generally received more help than more vulnerable communities.",
    "more_vulnerable":
        "Socially vulnerable communities were generally helped more than less socially vulnerable communities.",
    "balanced":
        "All communities were helped in roughly equal proportions, regardless of social vulnerability.",
}


def _bucket_index(label: str) -> float:
    """Extract the lower bound from a label like ``"0.4 - 0.5"`` for ordering."""
    match = re.match(r"\s*([0-9]+\.[0-9]+)", str(label))
    return float(match.group(1)) if match else float("nan")


def _parse_percentage(value: object) -> float:
    if isinstance(value, (int, float)):
        return float(value)
    s = str(value).strip().rstrip("%")
    try:
        return float(s)
    except ValueError:
        return float("nan")


def classify(csv_path: Path) -> tuple[str, float]:
    df = pd.read_csv(csv_path)
    if "svi_bin" not in df.columns or "percentage" not in df.columns:
        raise SystemExit("Input CSV must include 'svi_bin' and 'percentage' columns")

    df = df.copy()
    df["bucket_lo"] = df["svi_bin"].apply(_bucket_index)
    df["pct"] = df["percentage"].apply(_parse_percentage)
    df = df.dropna(subset=["bucket_lo", "pct"]).sort_values("bucket_lo")
    if df.empty:
        return CLASSIFICATIONS["balanced"], 0.0

    # Index 0 is the least-vulnerable bucket (0.0-0.1), index 9 is the most.
    x = np.arange(len(df))
    slope = float(np.polyfit(x, df["pct"].to_numpy(), 1)[0])

    if slope > SLOPE_THRESHOLD:
        key = "less_vulnerable"
    elif slope < -SLOPE_THRESHOLD:
        key = "more_vulnerable"
    else:
        key = "balanced"
    return CLASSIFICATIONS[key], slope


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="pipeline.svi_classification",
        description="Derive a one-line insight about the SVI completion distribution.",
    )
    parser.add_argument("--input", required=True, type=Path,
                        help="Path to an SVI percentages CSV (e.g. 12_needs_met_svi.csv).")
    parser.add_argument("--output", required=True, type=Path,
                        help="Output CSV. Writes columns 'classification' and 'slope'.")
    return parser.parse_args()


def main() -> None:
    args = _parse_args()
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)-7s %(message)s")

    classification, slope = classify(args.input)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    pd.DataFrame([{
        "classification": classification,
        "slope": round(slope, 3),
    }]).to_csv(args.output, index=False)
    logger.info("Wrote %s -- slope=%.3f", args.output, slope)


if __name__ == "__main__":
    main()
