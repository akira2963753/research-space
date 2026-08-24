"""Plot the measured high-side DEWA replacement-threshold PPL sweep."""

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
from matplotlib.ticker import MaxNLocator


EXPECTED_REPLACE_THRESHOLDS = (8, 4, 3, 2)
EXPECTED_SYMMETRIC_THRESHOLDS = (8, 7, 6, 5, 4, 3)
EXPECTED_SKIP_THRESHOLD = 8
EXPECTED_EXCEPTION_THRESHOLD = 8
SYMMETRIC_FILE_PATTERN = re.compile(
    r"w-bfp4-a-bie4-top2cap-dewa-fpacc-excskip-t(?P<threshold>\d+)-s2048\.json"
)


@dataclass(frozen=True)
class ReplaceSweepPoint:
    """One validated BFP4/Top-2-BiE4 DEWA measurement."""

    replace_threshold: int
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


def get_dewa_thresholds(
    dewa_config: dict[str, Any],
    path: Path,
) -> tuple[int, int, int]:
    """Accept both the symmetric legacy schema and asymmetric schema."""
    legacy_threshold = int(dewa_config.get("threshold_bits", -1))
    skip_threshold = int(
        dewa_config.get("skip_threshold_bits", legacy_threshold)
    )
    replace_threshold = int(
        dewa_config.get("replace_threshold_bits", legacy_threshold)
    )
    exception_threshold = int(
        dewa_config.get("exception_threshold_bits", legacy_threshold)
    )
    if min(skip_threshold, replace_threshold, exception_threshold) <= 0:
        raise ValueError(f"Invalid DEWA thresholds in {path}")
    return skip_threshold, replace_threshold, exception_threshold


def discover_replace_sweep(
    experiments_root: Path,
    baseline: dict[str, Any],
) -> tuple[float, dict[int, ReplaceSweepPoint]]:
    """Find the symmetric T=8 endpoint and asymmetric Treplace=4/3/2 runs."""
    result_dir = experiments_root / "09_Hybrid" / "llama2-7b"
    if not result_dir.is_dir():
        raise FileNotFoundError(f"Hybrid result directory not found: {result_dir}")

    fp16_baseline = float(baseline["perplexity"])
    top2_baseline: float | None = None
    points: dict[int, ReplaceSweepPoint] = {}

    for path in sorted(result_dir.glob("*.json")):
        payload = load_json(path)
        config = payload.get("hybrid_config")
        dewa_config = payload.get("dewa_config")
        if not isinstance(config, dict) or not isinstance(dewa_config, dict):
            continue
        if int(config.get("block_size", -1)) != 16:
            continue
        if 1 + int(config.get("mantissa_bits", -1)) != 4:
            continue
        if bool(config.get("quantize_lm_head", True)):
            continue
        if int(config.get("max_outliers_per_block", -1)) != 2:
            continue

        # The newer direct-FP-ACC sweep intentionally removed the legacy
        # exception threshold.  It belongs to a different experiment and must
        # not be parsed as part of this Tskip=Texc=8 comparison.
        if "exception_threshold_bits" not in dewa_config:
            continue

        skip_threshold, replace_threshold, exception_threshold = (
            get_dewa_thresholds(dewa_config, path)
        )
        if (
            skip_threshold != EXPECTED_SKIP_THRESHOLD
            or exception_threshold != EXPECTED_EXCEPTION_THRESHOLD
            or replace_threshold not in EXPECTED_REPLACE_THRESHOLDS
        ):
            continue

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
        if replace_threshold in points:
            raise ValueError(
                f"Duplicate Treplace={replace_threshold}: "
                f"{points[replace_threshold].path}, {path}"
            )
        points[replace_threshold] = ReplaceSweepPoint(
            replace_threshold=replace_threshold,
            perplexity=perplexity,
            path=path,
        )

    if top2_baseline is None:
        raise ValueError("No valid hybrid results were found")
    missing = sorted(set(EXPECTED_REPLACE_THRESHOLDS) - set(points))
    if missing:
        raise ValueError(f"Missing replacement-threshold results: {missing}")
    return top2_baseline, points


def discover_symmetric_sweep(
    experiments_root: Path,
    baseline: dict[str, Any],
    top2_baseline: float,
) -> dict[int, ReplaceSweepPoint]:
    """Find the symmetric T=8 through T=3 context series."""
    result_dir = experiments_root / "09_Hybrid" / "llama2-7b"
    fp16_baseline = float(baseline["perplexity"])
    points: dict[int, ReplaceSweepPoint] = {}

    for path in sorted(result_dir.glob("*.json")):
        match = SYMMETRIC_FILE_PATTERN.fullmatch(path.name)
        if match is None:
            continue
        threshold = int(match.group("threshold"))
        if threshold not in EXPECTED_SYMMETRIC_THRESHOLDS:
            continue

        payload = load_json(path)
        config = payload.get("hybrid_config")
        dewa_config = payload.get("dewa_config")
        if not isinstance(config, dict) or not isinstance(dewa_config, dict):
            raise ValueError(f"Missing hybrid/DEWA configuration in {path}")
        if int(config.get("block_size", -1)) != 16:
            continue
        if 1 + int(config.get("mantissa_bits", -1)) != 4:
            raise ValueError(f"Expected BFP4/BiE4 format in {path}")
        if bool(config.get("quantize_lm_head", True)):
            raise ValueError(f"Hybrid LM Head must remain FP16 in {path}")
        if int(config.get("max_outliers_per_block", -1)) != 2:
            raise ValueError(f"Expected Top-2 activation cap in {path}")

        thresholds = get_dewa_thresholds(dewa_config, path)
        if thresholds != (threshold, threshold, threshold):
            raise ValueError(f"Expected symmetric DEWA thresholds in {path}")
        validate_protocol(payload, baseline, path)
        fp16_reference = float(payload.get("fp16_baseline_perplexity", np.nan))
        if not np.isclose(fp16_reference, fp16_baseline, rtol=0.0, atol=1e-12):
            raise ValueError(f"FP16 baseline mismatch in {path}")
        point_top2_baseline = float(
            payload.get("top2_baseline_perplexity", np.nan)
        )
        if not np.isclose(
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
            raise ValueError(f"Duplicate symmetric T={threshold}: {path}")
        points[threshold] = ReplaceSweepPoint(
            replace_threshold=threshold,
            perplexity=perplexity,
            path=path,
        )

    missing = sorted(set(EXPECTED_SYMMETRIC_THRESHOLDS) - set(points))
    if missing:
        raise ValueError(f"Missing symmetric threshold results: {missing}")
    return points


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


def draw_asymmetric_segments(
    ax: plt.Axes,
    x: np.ndarray,
    values: np.ndarray,
    *,
    label: str,
) -> None:
    """Use a dashed connector across unmeasured T_replace=7 through 5."""
    color = "#E15759"
    ax.plot(
        x[:2],
        values[:2],
        color=color,
        linewidth=1.25,
        linestyle="--",
        zorder=2,
    )
    ax.plot(
        x[1:],
        values[1:],
        color=color,
        linewidth=1.25,
        linestyle="-",
        label=label,
        zorder=3,
    )
    ax.scatter(
        x,
        values,
        color=color,
        marker="s",
        s=23,
        edgecolor="0.20",
        linewidth=0.55,
        zorder=4,
    )


def style_axes(ax: plt.Axes) -> None:
    ax.grid(axis="y", color="0.84", linewidth=0.55, linestyle="--", zorder=0)
    ax.spines["top"].set_visible(False)
    ax.spines["right"].set_visible(False)
    ax.tick_params(direction="in", top=False, right=False)


def plot_replace_sweep(
    top2_baseline: float,
    asymmetric_points: dict[int, ReplaceSweepPoint],
    symmetric_points: dict[int, ReplaceSweepPoint],
    output_dir: Path,
) -> Path:
    asymmetric_thresholds = np.asarray(
        EXPECTED_REPLACE_THRESHOLDS,
        dtype=np.int64,
    )
    asymmetric_values = np.asarray(
        [
            asymmetric_points[int(threshold)].perplexity
            for threshold in asymmetric_thresholds
        ],
        dtype=np.float64,
    )
    symmetric_thresholds = np.asarray(
        EXPECTED_SYMMETRIC_THRESHOLDS,
        dtype=np.int64,
    )
    symmetric_values = np.asarray(
        [
            symmetric_points[int(threshold)].perplexity
            for threshold in symmetric_thresholds
        ],
        dtype=np.float64,
    )

    fig, (overview_ax, zoom_ax) = plt.subplots(
        1,
        2,
        figsize=(7.16, 2.35),
        gridspec_kw={"width_ratios": (1.15, 1.0)},
    )

    overview_ax.plot(
        symmetric_thresholds,
        symmetric_values,
        color="#4C78A8",
        linewidth=1.25,
        linestyle="-",
        marker="o",
        markersize=4.0,
        markerfacecolor="#4C78A8",
        markeredgecolor="0.20",
        markeredgewidth=0.55,
        label="Symmetric DEWA",
        zorder=3,
    )
    draw_asymmetric_segments(
        overview_ax,
        asymmetric_thresholds,
        asymmetric_values,
        label="Asymmetric DEWA",
    )
    overview_ax.axhline(
        top2_baseline,
        color="0.45",
        linewidth=0.9,
        linestyle="--",
        label="Top-2 baseline",
        zorder=1,
    )
    overview_ax.set_yscale("log")
    overview_ax.set_xlabel(r"Positive-side threshold")
    overview_ax.set_ylabel("Perplexity (PPL)")
    overview_ax.set_xticks(np.arange(2, 9))
    overview_ax.set_xlim(8.25, 1.75)
    overview_ax.set_ylim(top2_baseline * 0.85, symmetric_values.max() * 2.0)
    style_axes(overview_ax)
    overview_ax.legend(frameon=False, loc="upper left", handlelength=1.8)
    overview_ax.text(
        -0.12,
        1.015,
        "(a)",
        transform=overview_ax.transAxes,
        ha="left",
        va="bottom",
        clip_on=False,
    )

    zoom_positions = np.arange(len(asymmetric_thresholds), dtype=np.float64)
    draw_asymmetric_segments(
        zoom_ax,
        zoom_positions,
        asymmetric_values,
        label="Asymmetric DEWA",
    )
    zoom_ax.axhline(
        top2_baseline,
        color="0.45",
        linewidth=0.9,
        linestyle="--",
        label="Top-2 baseline",
        zorder=1,
    )
    zoom_ax.set_xlabel(r"$T_{\mathrm{replace}}$")
    zoom_ax.set_ylabel("Perplexity (PPL)")
    zoom_ax.set_xticks(
        zoom_positions,
        [str(threshold) for threshold in asymmetric_thresholds],
    )
    zoom_ax.set_xlim(-0.22, len(asymmetric_thresholds) - 0.78)
    zoom_ax.yaxis.set_major_locator(MaxNLocator(nbins=5))
    style_axes(zoom_ax)
    zoom_ax.legend(frameon=False, loc="upper left", handlelength=1.8)
    zoom_ax.text(
        0.98,
        0.03,
        r"$T_{\mathrm{skip}}=T_{\mathrm{exc}}=8$",
        transform=zoom_ax.transAxes,
        ha="right",
        va="bottom",
        fontsize=7,
    )
    zoom_ax.text(
        -0.12,
        1.015,
        "(b)",
        transform=zoom_ax.transAxes,
        ha="left",
        va="bottom",
        clip_on=False,
    )
    lower = min(top2_baseline, float(asymmetric_values.min()))
    upper = max(top2_baseline, float(asymmetric_values.max()))
    margin = max(0.006, 0.12 * (upper - lower))
    zoom_ax.set_ylim(lower - margin, upper + margin)

    output_dir.mkdir(parents=True, exist_ok=True)
    output_path = output_dir / "symmetric_asymmetric_treplace_ppl.png"
    fig.tight_layout(pad=0.35, w_pad=1.2)
    fig.savefig(output_path, dpi=600, bbox_inches="tight")
    fig.savefig(output_path.with_suffix(".pdf"), bbox_inches="tight")
    plt.close(fig)
    return output_path


def main() -> None:
    script_path = Path(__file__).resolve()
    research_root = script_path.parents[2]
    parser = argparse.ArgumentParser(
        description="Compare symmetric and asymmetric DEWA threshold PPL sweeps."
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
    top2_baseline, asymmetric_points = discover_replace_sweep(
        args.experiments_root,
        baseline,
    )
    symmetric_points = discover_symmetric_sweep(
        args.experiments_root,
        baseline,
        top2_baseline,
    )
    output_dir = (
        args.output_dir
        if args.output_dir is not None
        else script_path.parent / "figures" / "g16"
    )

    configure_ieee_style()
    for threshold in EXPECTED_REPLACE_THRESHOLDS:
        point = asymmetric_points[threshold]
        print(
            f"Treplace={threshold}: PPL={point.perplexity:.6f}; "
            f"Delta Top-2={point.perplexity - top2_baseline:+.6f}"
        )
    for threshold in EXPECTED_SYMMETRIC_THRESHOLDS:
        point = symmetric_points[threshold]
        print(f"Symmetric T={threshold}: PPL={point.perplexity:.6f}")
    print(
        "Saved: "
        + str(
            plot_replace_sweep(
                top2_baseline,
                asymmetric_points,
                symmetric_points,
                output_dir,
            )
        )
    )


if __name__ == "__main__":
    main()
