"""Prepare the area-code heatmap CSV for Kepler.gl.

Reads the raw heatmap CSV (which carries area-code polygons as binary WKB hex
in a ``geom`` column) and writes a Kepler-friendly variant with the geometry
expressed as WKT plus a log-scaled call-volume column suitable for a 20-step
colour gradient.
"""

from __future__ import annotations

import argparse
import logging
from pathlib import Path

import numpy as np
import pandas as pd
from shapely.wkb import loads as wkb_loads


logger = logging.getLogger(__name__)


def _wkb_to_wkt(value: object) -> str | None:
    if not isinstance(value, str) or not value:
        return None
    try:
        return wkb_loads(bytes.fromhex(value.strip())).wkt
    except Exception as exc:
        logger.warning("Skipping invalid WKB value: %s", exc)
        return None


def prepare(input_path: Path, output_path: Path) -> None:
    df = pd.read_csv(input_path, dtype=str)
    if "geom" not in df.columns or "calls" not in df.columns:
        raise SystemExit("Input CSV must include 'geom' and 'calls' columns")

    df["geom_wkt"] = df["geom"].apply(_wkb_to_wkt)
    df = df.dropna(subset=["geom_wkt"])

    df["calls"] = pd.to_numeric(df["calls"], errors="coerce").fillna(0)
    df["calls_log"] = np.log10(df["calls"] + 1)
    spread = df["calls_log"].max() - df["calls_log"].min()
    if spread > 0:
        df["calls_log_scaled"] = np.interp(
            df["calls_log"],
            (df["calls_log"].min(), df["calls_log"].max()),
            (1, 20),
        )
    else:
        df["calls_log_scaled"] = 1.0

    output_path.parent.mkdir(parents=True, exist_ok=True)
    df.to_csv(output_path, index=False)
    logger.info("Wrote %s (%d rows)", output_path, len(df))


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="pipeline.prepare_heatmap",
        description=(
            "Convert the heatmap CSV's geometry from WKB to WKT and add a "
            "log-scaled call-volume column for Kepler.gl."
        ),
    )
    parser.add_argument("--input", required=True, type=Path,
                        help="Raw heatmap CSV with a 'geom' WKB column.")
    parser.add_argument("--output", required=True, type=Path,
                        help="Output CSV path.")
    return parser.parse_args()


def main() -> None:
    args = _parse_args()
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)-7s %(message)s")
    prepare(args.input, args.output)


if __name__ == "__main__":
    main()
