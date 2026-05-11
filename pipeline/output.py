"""Output-directory layout and CSV writing."""

from __future__ import annotations

import logging
from pathlib import Path

import pandas as pd

from pipeline.mapping import OUTPUT_CATEGORIES


logger = logging.getLogger(__name__)


class OutputDir:
    """Creates and manages the directory tree for one pipeline run."""

    def __init__(self, base_path: Path):
        self.base = Path(base_path)

    def prepare(self, incident_ids: str, label: str) -> Path:
        """Create ``report_<ids>_<label>/`` with all category subdirectories."""
        slug = incident_ids.replace(",", "_")
        run_dir = self.base / f"report_{slug}_{label}"
        for sub in OUTPUT_CATEGORIES:
            (run_dir / sub).mkdir(parents=True, exist_ok=True)
        logger.info("Output directory: %s", run_dir)
        return run_dir


def write_csv(df: pd.DataFrame, run_dir: Path, category: str, name: str) -> bool:
    """Save ``df`` as ``run_dir/category/name.csv``."""
    if df is None or df.empty:
        logger.warning("No rows for %s/%s; skipping", category, name)
        return False
    target = run_dir / category / f"{name}.csv"
    try:
        df.to_csv(target, index=False, encoding="utf-8")
    except Exception as exc:
        logger.error("Could not write %s: %s", target, exc)
        return False
    logger.info("Wrote %s (%d rows, %d columns)", target, len(df), len(df.columns))
    return True
