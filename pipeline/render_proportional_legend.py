"""Render the colour-gradient legend bar used alongside the proportional-area chart.

Generates a horizontal colour bar interpolating between two endpoint colours
in N discrete steps, with percentage ticks. Output is a transparent PNG.
"""

from __future__ import annotations

import argparse
import logging
from pathlib import Path

import matplotlib.colors as mcolors
import matplotlib.pyplot as plt
import numpy as np


logger = logging.getLogger(__name__)


def render(
    output_path: Path,
    *,
    start_color: str,
    end_color: str,
    steps: int,
    tick_count: int,
) -> None:
    start = np.array(mcolors.to_rgb(start_color))
    end = np.array(mcolors.to_rgb(end_color))
    gradient = [
        mcolors.to_hex(start + (end - start) * i / (steps - 1))
        for i in range(steps)
    ]

    cmap = mcolors.ListedColormap(gradient)
    bounds = np.linspace(0, 1, len(gradient) + 1)
    norm = mcolors.BoundaryNorm(bounds, cmap.N)

    fig, ax = plt.subplots(figsize=(8, 1))
    tick_positions = np.linspace(0, 1, tick_count)
    tick_labels = [f"{int(t * 100)}%" for t in tick_positions]

    cb = plt.colorbar(
        plt.cm.ScalarMappable(cmap=cmap, norm=norm),
        cax=ax,
        orientation="horizontal",
        ticks=tick_positions,
    )
    cb.set_ticklabels(tick_labels)
    cb.ax.tick_params(labelsize=18)

    output_path.parent.mkdir(parents=True, exist_ok=True)
    plt.savefig(output_path, transparent=True, dpi=300, bbox_inches="tight")
    plt.close()
    logger.info("Saved %s", output_path)


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="pipeline.render_proportional_legend",
        description="Render the gradient legend bar for the proportional-area chart.",
    )
    parser.add_argument("--output", required=True, type=Path,
                        help="Output PNG path.")
    parser.add_argument("--start-color", default="#678ea8",
                        help="Hex colour for 0%% (default: #678ea8).")
    parser.add_argument("--end-color", default="#1c3c52",
                        help="Hex colour for 100%% (default: #1c3c52).")
    parser.add_argument("--steps", type=int, default=10,
                        help="Number of discrete colour bands (default: 10).")
    parser.add_argument("--ticks", type=int, default=6,
                        help="Number of tick labels including endpoints (default: 6).")
    return parser.parse_args()


def main() -> None:
    args = _parse_args()
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)-7s %(message)s")
    render(
        args.output,
        start_color=args.start_color,
        end_color=args.end_color,
        steps=args.steps,
        tick_count=args.ticks,
    )


if __name__ == "__main__":
    main()
