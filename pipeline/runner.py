"""End-to-end pipeline runner."""

from __future__ import annotations

import json
import logging
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Iterable

from pipeline import postprocess, substitution
from pipeline.database import DBConfig, Database, OmniView
from pipeline.mapping import (
    COUNTY_QUERIES,
    INCIDENT_QUERIES,
    STATE_QUERIES,
    SUPPORTING_QUERIES,
    Query,
)
from pipeline.output import OutputDir, write_csv


logger = logging.getLogger(__name__)


# Path to the bundled SQL templates.
SQL_ROOT = Path(__file__).resolve().parent.parent / "sql"


@dataclass
class RunConfig:
    incident_ids: str
    label: str
    output_root: Path
    db: DBConfig
    incident_type: str | None = None
    state_list: str | None = None
    check_freshness: bool = False
    skip_freshness_check: bool = False
    refresh: str = "none"          # "none" | "incremental" | "full"

    @property
    def incident_id_list(self) -> list[int]:
        return [int(part.strip()) for part in self.incident_ids.split(",")]

    @property
    def states(self) -> list[str]:
        if not self.state_list:
            return []
        return [s.strip() for s in self.state_list.split(",") if s.strip()]


@dataclass
class Report:
    """Audit log written alongside the CSV outputs."""

    start_time: str = field(default_factory=lambda: datetime.now().isoformat())
    end_time: str | None = None
    executed: list[dict] = field(default_factory=list)
    failed: list[dict] = field(default_factory=list)
    total_rows: int = 0
    omni_freshness: dict | None = None
    analysis_window: dict | None = None

    def record_success(self, sql_path: Path, output: str, df) -> None:
        self.executed.append(
            {
                "file": str(sql_path),
                "output": output,
                "rows": len(df),
                "columns": len(df.columns),
            }
        )
        self.total_rows += len(df)

    def record_failure(self, sql_path: Path, error: str) -> None:
        self.failed.append({"file": str(sql_path), "error": error})

    def save(self, run_dir: Path) -> None:
        self.end_time = datetime.now().isoformat()
        out = run_dir / "run_report.json"
        try:
            out.write_text(json.dumps(self.__dict__, indent=2, default=str, ensure_ascii=False))
            logger.info("Run report saved to %s", out)
        except Exception as exc:
            logger.error("Could not write run report: %s", exc)


class Pipeline:
    """Top-level orchestrator. Owns the lifecycle of a single pipeline run."""

    def __init__(self, config: RunConfig):
        self.config = config
        self.db = Database(config.db)
        self.omni = OmniView(self.db)
        self.output = OutputDir(config.output_root)
        self.report = Report()

    # ------------------------------------------------------------------ #
    # execution                                                          #
    # ------------------------------------------------------------------ #

    def run(self) -> bool:
        if not self.db.connect():
            return False

        try:
            if not self._handle_freshness():
                return False

            run_dir = self.output.prepare(self.config.incident_ids, self.config.label)

            self._run_queries(INCIDENT_QUERIES, run_dir)
            self._run_state_queries(run_dir)
            self._run_county_queries(run_dir)
            self._run_supporting(run_dir)

            postprocess.run(run_dir)
            self.report.save(run_dir)

            logger.info(
                "Pipeline finished. Executed=%d Failed=%d Rows=%d",
                len(self.report.executed),
                len(self.report.failed),
                self.report.total_rows,
            )
            return not self.report.failed
        finally:
            self.db.close()

    # ------------------------------------------------------------------ #
    # freshness + analysis window                                        #
    # ------------------------------------------------------------------ #

    def _handle_freshness(self) -> bool:
        config = self.config
        ids = config.incident_id_list

        if config.refresh != "none":
            ok = self.omni.refresh(ids, full=(config.refresh == "full"))
            if not ok:
                logger.error("Omni refresh failed")
                return False

        if config.skip_freshness_check and not config.check_freshness:
            return True

        fresh, details = self.omni.check_freshness(ids)
        self.report.omni_freshness = details
        if not fresh:
            logger.warning("Omni view is stale or missing incidents: %s", details)
            if "missing_incidents" in details:
                return False
            if not config.skip_freshness_check:
                logger.error(
                    "Refresh the omni view (--refresh incremental) or pass --skip-freshness-check."
                )
                return False
        else:
            logger.info("Omni view is fresh (%.1f hours old)", details["hours_since_update"])

        window = self.omni.analysis_window(ids)
        if window:
            logger.info(
                "Analysis window: %s -> %s (%d days)",
                window["start_date"],
                window["end_date"],
                window["total_days"],
            )
            self.report.analysis_window = window
        return True

    # ------------------------------------------------------------------ #
    # query execution                                                    #
    # ------------------------------------------------------------------ #

    def _read_sql(self, query: Query) -> str | None:
        path = SQL_ROOT / query.sql
        try:
            return path.read_text(encoding="utf-8")
        except FileNotFoundError:
            logger.error("SQL file missing: %s", path)
            self.report.record_failure(path, "File not found")
            return None

    def _process(self, sql: str, state: str | None = None) -> str:
        return substitution.apply_all(
            sql,
            incident_ids=self.config.incident_ids,
            state=state,
            state_list=self.config.state_list,
            incident_type=self.config.incident_type,
        )

    def _run_queries(self, queries: Iterable[Query], run_dir: Path) -> None:
        for q in queries:
            raw = self._read_sql(q)
            if raw is None:
                continue
            sql = self._process(raw)
            df = self.db.query(sql)
            sql_path = SQL_ROOT / q.sql
            if df is None:
                self.report.record_failure(sql_path, "Query execution failed")
                continue
            if write_csv(df, run_dir, q.category, q.output):
                self.report.record_success(sql_path, f"{q.category}/{q.output}.csv", df)

    def _run_state_queries(self, run_dir: Path) -> None:
        states = self.config.states
        if not states:
            logger.info("No --state-list provided; skipping state-level queries")
            return

        for state in states:
            logger.info("Running state-level queries for %s", state)
            for q in STATE_QUERIES:
                raw = self._read_sql(q)
                if raw is None:
                    continue
                sql = self._process(raw, state=state)
                df = self.db.query(sql)
                sql_path = SQL_ROOT / q.sql
                if df is None:
                    self.report.record_failure(sql_path, f"Query execution failed for {state}")
                    continue
                if df.empty:
                    logger.warning("State query %s returned no rows for %s", q.output, state)
                    continue
                name = f"{state}_{q.output}"
                if write_csv(df, run_dir, q.category, name):
                    self.report.executed.append(
                        {
                            "file": str(sql_path),
                            "output": f"{q.category}/{name}.csv",
                            "rows": len(df),
                            "columns": len(df.columns),
                            "type": "state-level",
                            "state": state,
                        }
                    )
                    self.report.total_rows += len(df)

    def _run_county_queries(self, run_dir: Path) -> None:
        """County-level queries run once per state (same pattern as state-level)."""
        states = self.config.states
        if not states:
            logger.info("No --state-list provided; skipping county-level queries")
            return

        for state in states:
            logger.info("Running county-level queries for %s", state)
            for q in COUNTY_QUERIES:
                raw = self._read_sql(q)
                if raw is None:
                    continue
                sql = self._process(raw, state=state)
                df = self.db.query(sql)
                sql_path = SQL_ROOT / q.sql
                if df is None:
                    self.report.record_failure(sql_path, f"Query execution failed for {state}")
                    continue
                if df.empty:
                    logger.warning("County query %s returned no rows for %s", q.output, state)
                    continue
                name = f"{state}_{q.output}"
                if write_csv(df, run_dir, q.category, name):
                    self.report.executed.append(
                        {
                            "file": str(sql_path),
                            "output": f"{q.category}/{name}.csv",
                            "rows": len(df),
                            "columns": len(df.columns),
                            "type": "county-level",
                            "state": state,
                        }
                    )
                    self.report.total_rows += len(df)

    def _run_supporting(self, run_dir: Path) -> None:
        for q in SUPPORTING_QUERIES:
            raw = self._read_sql(q)
            if raw is None:
                continue
            sql = self._process(raw)
            df = self.db.query(sql)
            sql_path = SQL_ROOT / q.sql
            if df is None:
                self.report.record_failure(sql_path, "Query execution failed")
                continue
            if write_csv(df, run_dir, q.category, q.output):
                self.report.record_success(sql_path, f"{q.category}/{q.output}.csv", df)
