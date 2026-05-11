"""Command-line entry point."""

from __future__ import annotations

import argparse
import logging
import sys
from datetime import date
from pathlib import Path

from pipeline.database import DBConfig
from pipeline.runner import Pipeline, RunConfig


def _setup_logging() -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)-7s %(message)s",
        handlers=[logging.StreamHandler(), logging.FileHandler("pipeline.log")],
    )


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="pipeline",
        description=(
            "Run the disaster-relief reporting pipeline for one or more "
            "incidents. Outputs a directory of CSVs ready for downstream "
            "visualisation."
        ),
    )

    parser.add_argument(
        "--incident-ids",
        required=True,
        help='Comma-separated incident IDs (e.g. "185" or "175,172,180")',
    )
    parser.add_argument(
        "--label",
        default=date.today().isoformat(),
        help="Label appended to the output directory (defaults to today's date)",
    )
    parser.add_argument(
        "--output-path",
        default="/mnt/data",
        type=Path,
        help="Root directory for output files (default: /mnt/data)",
    )

    db = parser.add_argument_group("database")
    db.add_argument("--db-host",     required=True)
    db.add_argument("--db-user",     required=True)
    db.add_argument("--db-password", required=True)
    db.add_argument("--db-port",     type=int, default=5432)
    db.add_argument("--db-name",     default="crisiscleanup")

    filters = parser.add_argument_group("filters")
    filters.add_argument(
        "--incident-type",
        help='Incident type for the front-cover statistic (e.g. "tornado", "hurricane")',
    )
    filters.add_argument(
        "--state-list",
        help='Comma-separated two-letter state codes (e.g. "MO,KY,WV")',
    )

    omni = parser.add_argument_group("materialised view")
    omni.add_argument(
        "--refresh",
        choices=("none", "incremental", "full"),
        default="none",
        help="Refresh the analytics view before running queries",
    )
    omni.add_argument(
        "--check-freshness",
        action="store_true",
        help="Fail the run if the analytics view has not been updated in the last 24 hours",
    )
    omni.add_argument(
        "--skip-freshness-check",
        action="store_true",
        help="Run even if the analytics view is stale",
    )

    return parser.parse_args()


def main() -> None:
    args = _parse_args()
    _setup_logging()

    config = RunConfig(
        incident_ids=args.incident_ids,
        label=args.label,
        output_root=args.output_path,
        db=DBConfig(
            host=args.db_host,
            user=args.db_user,
            password=args.db_password,
            port=args.db_port,
            database=args.db_name,
        ),
        incident_type=args.incident_type,
        state_list=args.state_list,
        check_freshness=args.check_freshness,
        skip_freshness_check=args.skip_freshness_check,
        refresh=args.refresh,
    )

    pipeline = Pipeline(config)
    success = pipeline.run()
    sys.exit(0 if success else 1)


if __name__ == "__main__":
    main()
