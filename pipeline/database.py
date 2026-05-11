"""PostgreSQL access and materialised-view bookkeeping."""

from __future__ import annotations

import logging
from dataclasses import dataclass
from datetime import datetime
from typing import Sequence

import pandas as pd
from sqlalchemy import create_engine, text
from sqlalchemy.engine import Engine


logger = logging.getLogger(__name__)

# Source of truth for the analytics view used throughout the SQL templates.
OMNI_VIEW = "r.cases_new_claimed_closed_omni_mag"

# Maximum staleness (in hours) tolerated before the freshness check fails.
FRESHNESS_HOURS = 24


@dataclass(frozen=True)
class DBConfig:
    host: str
    user: str
    password: str
    port: int = 5432
    database: str = "crisiscleanup"

    def url(self) -> str:
        return (
            f"postgresql+psycopg2://{self.user}:{self.password}"
            f"@{self.host}:{self.port}/{self.database}"
        )


class Database:
    """Thin wrapper over a SQLAlchemy engine."""

    def __init__(self, config: DBConfig):
        self._config = config
        self._engine: Engine | None = None

    def connect(self) -> bool:
        try:
            self._engine = create_engine(self._config.url())
            with self._engine.connect() as conn:
                conn.execute(text("SELECT 1"))
        except Exception as exc:
            logger.error("Database connection failed: %s", exc)
            return False
        logger.info("Connected to %s:%s", self._config.host, self._config.port)
        return True

    def query(self, sql: str) -> pd.DataFrame | None:
        """Run ``sql`` and return the result as a DataFrame.

        Returns ``None`` when execution fails so the caller can record the
        error in the run report without aborting the rest of the pipeline.
        """
        assert self._engine is not None, "call connect() before query()"
        try:
            with self._engine.connect() as conn:
                df = pd.read_sql_query(text(sql), conn)
        except Exception as exc:
            logger.error("Query failed: %s", exc)
            return None
        logger.info("Query returned %d rows", len(df))
        return df

    def execute(self, sql: str) -> bool:
        """Run a statement that doesn't return rows (e.g. ``CALL``)."""
        assert self._engine is not None, "call connect() before execute()"
        try:
            with self._engine.connect() as conn:
                conn.execute(text(sql))
                conn.commit()
        except Exception as exc:
            logger.error("Statement failed: %s", exc)
            return False
        return True

    def close(self) -> None:
        if self._engine is not None:
            self._engine.dispose()
            self._engine = None


class OmniView:
    """Operations specific to the analytics materialised view."""

    def __init__(self, db: Database):
        self._db = db

    def check_freshness(self, incident_ids: Sequence[int]) -> tuple[bool, dict]:
        """Confirm the view has data for every incident, and recent updates."""
        id_list = ",".join(map(str, incident_ids))
        sql = f"""
            SELECT
                incident_id,
                MAX(the_date)    AS last_snapshot,
                MAX(updated_at)  AS last_update,
                COUNT(*)         AS total_records
            FROM {OMNI_VIEW}
            WHERE incident_id = ANY(string_to_array('{id_list}', ',')::int[])
            GROUP BY incident_id
            ORDER BY incident_id
        """
        df = self._db.query(sql)
        if df is None or df.empty:
            return False, {"error": "No data found for the requested incidents"}

        missing = set(incident_ids) - set(df["incident_id"].tolist())
        if missing:
            return False, {"missing_incidents": sorted(missing)}

        last_update = pd.to_datetime(df["last_update"].max())
        age_hours = (datetime.now() - last_update.to_pydatetime().replace(tzinfo=None)).total_seconds() / 3600
        details = {
            "incidents": df.to_dict("records"),
            "last_update": last_update.isoformat(),
            "hours_since_update": round(age_hours, 1),
            "is_fresh": age_hours < FRESHNESS_HOURS,
        }
        return details["is_fresh"], details

    def refresh(self, incident_ids: Sequence[int], full: bool = False) -> bool:
        """Trigger the refresh stored procedure.

        ``full=False`` runs an incremental refresh over the trailing 12 hours;
        ``full=True`` rebuilds the view for the supplied incidents entirely.
        """
        id_list = ",".join(map(str, incident_ids))
        recent = "null" if full else "0"
        mode = "full" if full else "incremental"
        logger.info("Starting %s refresh for incidents %s", mode, id_list)
        sql = (
            "CALL create_cases_new_claimed_closed_omni_mag("
            f"{recent}, NOW(), ARRAY[{id_list}]::int[], null, null);"
        )
        return self._db.execute(sql)

    def analysis_window(self, incident_ids: Sequence[int]) -> dict | None:
        """Return the date range flagged ``is_within_analysis`` per incident."""
        id_list = ",".join(map(str, incident_ids))
        sql = f"""
            SELECT
                incident_id,
                MIN(the_date) AS analysis_start,
                MAX(the_date) AS analysis_end,
                COUNT(DISTINCT the_date) AS days_in_analysis
            FROM {OMNI_VIEW}
            WHERE incident_id = ANY(string_to_array('{id_list}', ',')::int[])
              AND is_within_analysis = true
            GROUP BY incident_id
            ORDER BY incident_id
        """
        df = self._db.query(sql)
        if df is None or df.empty:
            return None
        start = pd.to_datetime(df["analysis_start"].min())
        end = pd.to_datetime(df["analysis_end"].max())
        return {
            "start_date": start.isoformat(),
            "end_date": end.isoformat(),
            "total_days": (end - start).days + 1,
            "incidents": df.to_dict("records"),
        }
