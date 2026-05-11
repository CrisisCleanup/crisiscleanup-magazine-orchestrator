"""Prepare the volunteer-locations CSV for the magazine's volunteer map.

The pipeline produces a CSV with a ``point`` column encoded as binary WKB
hex. The mapping tool (Kepler.gl) wants the geometry expressed as WKT and
finds a ``call_count`` column more useful than the underlying user table's
mixed-type values.
"""

from __future__ import annotations

import argparse
import logging
from pathlib import Path

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
    if "point" not in df.columns:
        raise SystemExit("Input CSV must include a 'point' column")

    df["point_wkt"] = df["point"].apply(_wkb_to_wkt)
    df = df.dropna(subset=["point_wkt"])
    df = df.drop(columns=["point"])

    if "call_count" in df.columns:
        df["call_count"] = pd.to_numeric(df["call_count"], errors="coerce").fillna(0).astype(int)

    output_path.parent.mkdir(parents=True, exist_ok=True)
    df.to_csv(output_path, index=False)
    logger.info("Wrote %s (%d rows)", output_path, len(df))


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="pipeline.prepare_volunteer_locations",
        description="Convert volunteer-location geometry from WKB to WKT.",
    )
    parser.add_argument("--input", required=True, type=Path,
                        help="Raw volunteer-locations CSV with a 'point' WKB column.")
    parser.add_argument("--output", required=True, type=Path,
                        help="Output CSV path.")
    return parser.parse_args()


def main() -> None:
    args = _parse_args()
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)-7s %(message)s")
    prepare(args.input, args.output)


if __name__ == "__main__":
    main()
