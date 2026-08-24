"""Plot the complete symmetric Hybrid BFP4 DEWA threshold sweep on log PPL."""

from __future__ import annotations

import argparse
import json
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import matplotlib
import numpy as np

matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.ticker import MultipleLocator


EXPECTED_THRESHOLDS = tuple(range(3, 13))
RESULT_PATTERN = re.compile(
    r"w-bfp4-a-bie4-top2cap-dewa-fpacc-excskip-t(?P<threshold>\d+)-s2048\.json"
)


@dataclass(frozen=True)
class SweepPoint:
    """One validated symmetric Hybrid BFP4 DEWA measurement."""

    threshold: int
    perplexity: float
    path: Path


def load_json(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as file:
        return json.load(file)


def validate_protocol(
    payload: dict[str, Any],
    baseline: dict[str, Any],
    path: Path,
) -> None:
    for key in (
        "model",
        "dataset",
        "split",
        "evaluation_protocol",
        "context_length",
        "stride",
        "drop_remainder",
        "evaluated_tokens",
    ):
        if payload.get(key) != baseline.get(key):
            raise ValueError(f"Protocol mismatch for '{key}' in {path}")


def discover_symmetric_sweep(
    experiments_root: Path,
    baseline: dict[str, Any],
) -> tuple[float, dict[int, SweepPoint]]:
    """Load and validate the archived T=3 through T=12 symmetric sweep."""
    result_dir = experiments_root / "09_Hybrid" / "llama2-7b"
    if not result_dir.is_dir():
        raise FileNotFoundError(f"Hybrid result directory not found: {result_dir}")

    fp16_baseline = float(baseline["perplexity"])
    top2_baseline: float | None = None
    points: dict[int, SweepPoint] = {}

    for path in sorted(result_dir.glob("*.json")):
        match = RESULT_PATTERN.fullmatch(path.name)
        if match is None:
            continue

        threshold = int(match.group("threshold"))
        if threshold not in EXPECTED_THRESHOLDS:
            continue

        payload = load_json(path)
        hybrid_config = payload.get("hybrid_config")
        dewa_config = payload.get("dewa_config")
        if not isinstance(hybrid_config, dict) or not isinstance(dewa_config, dict):
            raise ValueError(f"Missing Hybrid/DEWA configuration in {path}")

        if int(hybrid_config.get("block_size", -1)) != 16:
            raise ValueError(f"Expected Group-16 configuration in {path}")
        if 1 + int(hybrid_config.get("mantissa_bits", -1)) != 4:
            raise ValueError(f"Expected BFP4/BiE4 mantissa format in {path}")
        if bool(hybrid_config.get("quantize_lm_head", True)):
            raise ValueError(f"LM head must remain FP16 in {path}")
        if int(hybrid_config.get("max_outliers_per_block", -1)) != 2:
            raise ValueError(f"Expected Top-2 activation cap in {path}")

        normal_threshold = int(dewa_config.get("threshold_bits", -1))
        exception_threshold = int(
            dewa_config.get("exception_threshold_bits", -1)
        )
        if (normal_threshold, exception_threshold) != (threshold, threshold):
            raise ValueError(
                f"Expected symmetric T={threshold} in {path}; found "
                f"({normal_threshold}, {exception_threshold})"
            )

        validate_protocol(payload, baseline, path)
        fp16_reference = float(payload.get("fp16_baseline_perplexity", np.nan))
        if not np.isclose(fp16_reference, fp16_baseline, rtol=0.0, atol=1e-12):
            raise ValueError(f"FP16 baseline mismatch in {path}")

        point_top2_baseline = float(
            payload.get("top2_baseline_perplexity", np.nan)
        )
        if not np.isfinite(point_top2_baseline):
            raise ValueError(f"Missing Top-2 baseline in {path}")
        if top2_baseline is None:
            top2_baseline = point_top2_baseline
        elif not np.isclose(
            point_top2_baseline,
            top2_baseline,
            rtol=0.0,
            atol=1e-12,
        ):
            raise ValueError(f"Top-2 baseline mismatch in {path}")

        perplexity = float(payload.get("perplexity", np.nan))
        if not np.isfinite(perplexity) or perplexity <= 0.0:
            raise ValueError(f"Invalid PPL in {path}")
        if threshold in points:
            raise ValueError(
                f"Duplicate symmetric threshold T={threshold}: "
                f"{points[threshold].path}, {path}"
            )
        points[threshold] = SweepPoint(
            threshold=threshold,
            perplexity=perplexity,
            path=path,
        )

    missing = sorted(set(EXPECTED_THRESHOLDS) - set(points))
    if missing:
        raise ValueError(f"Missing symmetric DEWA threshold results: {missing}")
    if top2_baseline is None:
        raise ValueError("No valid symmetric Hybrid results were found")
    return top2_baseline, points


def configure_ieee_style() -> None:
    plt.rcParams.update(
        {
            "font.family": "serif",
            "font.serif": ["Times New Roman", "Times", "DejaVu Serif"],
            "font.size": 8,
            "axes.labelsize": 8,
            "xtick.labelsize": 7,
            "ytick.labelsize": 7,
            "legend.fontsize": 7,
            "axes.linewidth": 0.8,
            "xtick.major.width": 0.8,
            "ytick.major.width": 0.8,
            "xtick.major.size": 3,
            "ytick.major.size": 3,
            "mathtext.fontset": "stix",
            "pdf.fonttype": 42,
            "ps.fonttype": 42,
            "savefig.facecolor": "white",
        }
    )


def style_axes(ax: plt.Axes) -> None:
    ax.grid(axis="y", color="0.84", linewidth=0.55, linestyle="--", zorder=0)
    ax.spines["top"].set_visible(False)
    ax.spines["right"].set_visible(False)
    ax.tick_params(direction="in", top=False, right=False)


def plot_symmetric_sweep(
    top2_baseline: float,
    points: dict[int, SweepPoint],
    output_dir: Path,
) -> Path:
    thresholds = np.asarray(EXPECTED_THRESHOLDS, dtype=np.int64)
    perplexities = np.asarray(
        [points[int(threshold)].perplexity for threshold in thresholds],
        dtype=np.float64,
    )
    zoom_thresholds = thresholds[thresholds >= 7]
    zoom_perplexities = perplexities[thresholds >= 7]

    fig, (overview_ax, zoom_ax) = plt.subplots(
        1,
        2,
        figsize=(7.16, 2.65),
        gridspec_kw={"width_ratios": (1.15, 1.0)},
    )

    overview_ax.plot(
        thresholds,
        perplexities,
        color="#4C78A8",
        linewidth=1.3,
        linestyle="-",
        marker="o",
        markersize=4.0,
        markerfacecolor="#4C78A8",
        markeredgecolor="0.20",
        markeredgewidth=0.55,
        label="Symmetric Hybrid DEWA",
        zorder=3,
    )
    overview_ax.axhline(
        top2_baseline,
        color="0.42",
        linewidth=0.9,
        linestyle="--",
        label="Top-2 A-BiE4 baseline",
        zorder=1,
    )
    overview_ax.set_yscale("log")
    overview_ax.set_ylabel("Perplexity (PPL, log scale)")
    overview_ax.set_xticks(thresholds)
    overview_ax.set_xlim(
        float(thresholds.min()) - 0.25,
        float(thresholds.max()) + 0.25,
    )
    overview_ax.set_ylim(top2_baseline * 0.88, perplexities.max() * 1.8)
    style_axes(overview_ax)
    overview_ax.legend(frameon=False, loc="upper right", handlelength=1.8)

    zoom_ax.plot(
        zoom_thresholds,
        zoom_perplexities,
        color="#4C78A8",
        linewidth=1.3,
        linestyle="-",
        marker="o",
        markersize=4.0,
        markerfacecolor="#4C78A8",
        markeredgecolor="0.20",
        markeredgewidth=0.55,
        zorder=3,
    )
    zoom_ax.axhline(
        top2_baseline,
        color="0.42",
        linewidth=0.9,
        linestyle="--",
        zorder=1,
    )
    zoom_ax.set_ylabel("Perplexity (PPL)")
    zoom_ax.set_xticks(zoom_thresholds)
    zoom_ax.set_xlim(
        float(zoom_thresholds.min()) - 0.15,
        float(zoom_thresholds.max()) + 0.15,
    )
    zoom_ax.set_ylim(6.00, 6.60)
    zoom_ax.yaxis.set_major_locator(MultipleLocator(0.10))
    zoom_ax.yaxis.set_minor_locator(MultipleLocator(0.02))
    zoom_ax.tick_params(axis="y", which="minor", length=2)
    style_axes(zoom_ax)
    zoom_ax.text(
        0.98,
        0.94,
        r"Zoom: $T=7$--$12$ (linear scale)",
        transform=zoom_ax.transAxes,
        ha="right",
        va="top",
        fontsize=7,
    )

    output_dir.mkdir(parents=True, exist_ok=True)
    output_path = output_dir / "hybrid_symmetric_ppl_log_zoom_t3-12.png"
    fig.supxlabel(r"Symmetric DEWA threshold, $T$", y=0.01)
    fig.tight_layout(rect=(0.0, 0.07, 1.0, 1.0), pad=0.35, w_pad=1.1)
    fig.savefig(output_path, dpi=600, bbox_inches="tight")
    fig.savefig(output_path.with_suffix(".pdf"), bbox_inches="tight")
    plt.close(fig)
    return output_path


def main() -> None:
    script_path = Path(__file__).resolve()
    research_root = script_path.parents[2]
    parser = argparse.ArgumentParser(
        description="Plot the full symmetric Hybrid BFP4 DEWA PPL sweep."
    )
    parser.add_argument(
        "--experiments-root",
        type=Path,
        default=research_root / "experiments",
    )
    parser.add_argument("--output-dir", type=Path, default=None)
    args = parser.parse_args()

    baseline_path = (
        args.experiments_root / "01_Baseline" / "llama2-7b" / "baseline.json"
    )
    baseline = load_json(baseline_path)
    top2_baseline, points = discover_symmetric_sweep(
        args.experiments_root,
        baseline,
    )
    output_dir = (
        args.output_dir
        if args.output_dir is not None
        else script_path.parent / "figures" / "g16"
    )

    configure_ieee_style()
    for threshold in EXPECTED_THRESHOLDS:
        point = points[threshold]
        print(f"T={threshold}: PPL={point.perplexity:.6f}")
    print(f"Top-2 baseline: PPL={top2_baseline:.6f}")
    print("Saved: " + str(plot_symmetric_sweep(top2_baseline, points, output_dir)))


if __name__ == "__main__":
    main()
