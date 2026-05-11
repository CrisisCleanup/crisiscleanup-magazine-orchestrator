"""Publish per-county commercial-value charts to Infogram and download PDFs.

Reads a CSV of county-level commercial values produced by the
``sql/county_summary/commercial_value.sql`` query and, for each unique
county/area:

1. Updates the data table backing a specific chart element in an Infogram
   project (``updateProjectEntities``).
2. Kicks off a PDF export of the project (``downloadProject``).
3. Polls the export task over Server-Sent Events (``getTaskStatus``).
4. Downloads the resulting PDF and writes it to disk.

All Infogram credentials and identifiers are read from the environment so no
secrets land in the repo:

* ``INFOGRAM_API_KEY``     -- Bearer token for the REST API.
* ``INFOGRAM_PROJECT_ID``  -- Target project to update.
* ``INFOGRAM_ELEMENT_ID``  -- The chart element to overwrite within that
  project.

Expected input columns:

* ``name``                       -- county or area name.
* ``location_id``                -- integer used in the output PDF filename.
* ``work_type_key``              -- lower-case work-type identifier.
* ``closed_commercial_value``    -- numeric.
* ``open_claimed_value``         -- numeric.
* ``open_unclaimed_value``       -- numeric.

Usage::

    python -m pipeline.publish_infogram \\
        --input /path/to/commercial_value.csv \\
        --output-dir ./infogram_pdfs
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import sys
from dataclasses import dataclass
from pathlib import Path

import pandas as pd
import requests
import sseclient


logger = logging.getLogger(__name__)


INFOGRAM_BASE = "https://api.infogram.com"
UPDATE_URL    = f"{INFOGRAM_BASE}/updateProjectEntities"
DOWNLOAD_URL  = f"{INFOGRAM_BASE}/downloadProject"
STATUS_URL    = f"{INFOGRAM_BASE}/getTaskStatus"

# Work-type order and display labels used in the chart's first row.
WORK_TYPES: tuple[tuple[str, str], ...] = (
    ("trees",    "Trees"),
    ("debris",   "Debris"),
    ("muck_out", "Muck Out"),
    ("fence",    "Fence"),
    ("tarp",     "Tarp"),
    ("other",    "Other"),
)


# --------------------------------------------------------------------------- #
# client                                                                      #
# --------------------------------------------------------------------------- #


@dataclass(frozen=True)
class InfogramConfig:
    api_key: str
    project_id: str
    element_id: str

    @classmethod
    def from_env(cls) -> "InfogramConfig":
        api_key    = os.environ.get("INFOGRAM_API_KEY")
        project_id = os.environ.get("INFOGRAM_PROJECT_ID")
        element_id = os.environ.get("INFOGRAM_ELEMENT_ID")
        missing = [
            name for name, value in [
                ("INFOGRAM_API_KEY",    api_key),
                ("INFOGRAM_PROJECT_ID", project_id),
                ("INFOGRAM_ELEMENT_ID", element_id),
            ] if not value
        ]
        if missing:
            raise SystemExit(
                "Missing required environment variable(s): " + ", ".join(missing)
            )
        return cls(api_key=api_key, project_id=project_id, element_id=element_id)


class InfogramClient:
    def __init__(self, config: InfogramConfig):
        self._config = config

    def _headers(self) -> dict[str, str]:
        return {
            "Authorization": f"Bearer {self._config.api_key}",
            "Content-Type":  "application/json",
        }

    def update_chart(self, rows: pd.DataFrame) -> None:
        payload = {
            "projectId": self._config.project_id,
            "entities":  {self._config.element_id: {"data": _build_sheet(rows)}},
        }
        response = requests.post(UPDATE_URL, headers=self._headers(), data=json.dumps(payload))
        response.raise_for_status()

    def export_pdf(self) -> bytes:
        payload = {
            "projectId":             self._config.project_id,
            "format":                "pdf",
            "transparentBackground": False,
        }
        response = requests.post(DOWNLOAD_URL, headers=self._headers(), data=json.dumps(payload))
        response.raise_for_status()
        task_id = response.json().get("taskId")
        if not task_id:
            raise RuntimeError("Infogram did not return a download task id")

        download_url = self._wait_for_task(task_id)
        pdf = requests.get(download_url)
        pdf.raise_for_status()
        return pdf.content

    def _wait_for_task(self, task_id: str) -> str:
        url = f"{STATUS_URL}?taskId={task_id}&type=download"
        client = sseclient.SSEClient(url, headers={
            "Authorization": f"Bearer {self._config.api_key}",
            "Content-Type":  "application/json; charset=utf-8",
        })
        for event in client:
            if event.event == "message":
                payload = json.loads(event.data).get("data", {})
                if payload.get("error"):
                    raise RuntimeError(f"Infogram task {task_id} reported an error")
                progress = payload.get("progress", 0)
                logger.info("Task %s: %d%%", task_id, progress)
                if progress == 100:
                    url = payload.get("result", {}).get("url")
                    if not url:
                        raise RuntimeError(f"Task {task_id} completed without a download URL")
                    return url
            elif event.event == "error":
                raise RuntimeError(f"Infogram SSE error: {event.data}")
        raise RuntimeError(f"Infogram task {task_id} closed before completion")


# --------------------------------------------------------------------------- #
# CSV -> Infogram payload                                                     #
# --------------------------------------------------------------------------- #


def _build_sheet(rows: pd.DataFrame) -> list[dict]:
    """Shape one county's rows into the array-of-arrays Infogram expects."""
    header = ["Work Type", "Closed", "Claimed", "Open Unclaimed"]
    data = [header]
    for key, label in WORK_TYPES:
        match = rows[rows["work_type_key"] == key]
        if match.empty:
            closed = claimed = unclaimed = 0
        else:
            closed    = match["closed_commercial_value"].sum()
            claimed   = match["open_claimed_value"].sum()
            unclaimed = match["open_unclaimed_value"].sum()
        data.append([label, str(closed), str(claimed), str(unclaimed)])
    return [{"title": "Sheet 1", "data": data}]


# --------------------------------------------------------------------------- #
# orchestration                                                               #
# --------------------------------------------------------------------------- #


REQUIRED_COLUMNS = (
    "name",
    "location_id",
    "work_type_key",
    "closed_commercial_value",
    "open_claimed_value",
    "open_unclaimed_value",
)


def publish_counties(csv_path: Path, output_dir: Path, client: InfogramClient) -> None:
    df = pd.read_csv(csv_path)
    missing = [c for c in REQUIRED_COLUMNS if c not in df.columns]
    if missing:
        raise SystemExit(f"Input CSV is missing required columns: {missing}")
    output_dir.mkdir(parents=True, exist_ok=True)

    for area_name in df["name"].dropna().unique():
        rows = df[df["name"] == area_name]
        location_id = rows["location_id"].iloc[0]
        logger.info("Publishing %s (location_id=%s)", area_name, location_id)

        client.update_chart(rows)
        pdf_bytes = client.export_pdf()

        safe_name = str(area_name).replace("/", "_").replace(" ", "_")
        output_path = output_dir / f"{location_id}_{safe_name}_value.pdf"
        output_path.write_bytes(pdf_bytes)
        logger.info("Saved %s", output_path)


# --------------------------------------------------------------------------- #
# CLI                                                                         #
# --------------------------------------------------------------------------- #


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="pipeline.publish_infogram",
        description=(
            "Push per-county commercial-value charts to Infogram and download "
            "the resulting PDFs. Credentials are read from environment "
            "variables (INFOGRAM_API_KEY, INFOGRAM_PROJECT_ID, "
            "INFOGRAM_ELEMENT_ID)."
        ),
    )
    parser.add_argument(
        "--input",
        required=True,
        type=Path,
        help="Path to commercial_value.csv produced by the pipeline.",
    )
    parser.add_argument(
        "--output-dir",
        required=True,
        type=Path,
        help="Directory where the per-county PDFs will be written.",
    )
    return parser.parse_args()


def main() -> None:
    args = _parse_args()
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)-7s %(message)s",
    )
    client = InfogramClient(InfogramConfig.from_env())
    publish_counties(args.input, args.output_dir, client)


if __name__ == "__main__":
    main()
