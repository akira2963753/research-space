"""Plot selected Hybrid (T_skip, T_replace) PPL points against Top-2."""

from __future__ import annotations

import argparse
import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import matplotlib
import numpy as np

matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.ticker import FormatStrFormatter


T9_REPLACE_THRESHOLDS = tuple(range(9, 1, -1))
DESIGN_POINTS = (
    (8, 8),
    *((9, replace_threshold) for replace_threshold in T9_REPLACE_THRESHOLDS),
    (10, 10),
)
HYBRID_DIR = Path("09_Hybrid") / "llama2-7b"
SYMMETRIC_NAME = (
    "w-bfp4-a-bie4-top2cap-dewa-fpacc-excskip-t{threshold}-s2048.json"
)
ASYMMETRIC_NAME = (
    "w-bfp4-a-bie4-top2cap-asym-dewa-fpacc-tskip9-"
    "treplace{replace_threshold}-s2048.json"
)


@dataclass(frozen=True)
class DesignPoint:
    """One validated Hybrid (T_skip, T_replace) measurement."""

    skip_threshold: int
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


def validate_hybrid_format(payload: dict[str, Any], path: Path) -> dict[str, Any]:
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
    return dewa_config


def result_path(
    experiments_root: Path,
    skip_threshold: int,
    replace_threshold: int,
) -> Path:
    result_dir = experiments_root / HYBRID_DIR
    if skip_threshold == replace_threshold:
        name = SYMMETRIC_NAME.format(threshold=skip_threshold)
    elif skip_threshold == 9:
        name = ASYMMETRIC_NAME.format(replace_threshold=replace_threshold)
    else:
        raise ValueError(
            f"No canonical Hybrid JSON for ({skip_threshold}, {replace_threshold})"
        )
    return result_dir / name


def load_design_point(
    path: Path,
    skip_threshold: int,
    replace_threshold: int,
    baseline: dict[str, Any],
    top2_baseline: float | None,
) -> tuple[DesignPoint, float]:
    if not path.is_file():
        raise FileNotFoundError(f"Hybrid result not found: {path}")

    payload = load_json(path)
    dewa_config = validate_hybrid_format(payload, path)
    validate_protocol(payload, baseline, path)

    if skip_threshold == replace_threshold:
        recorded_threshold = int(dewa_config.get("threshold_bits", -1))
        if recorded_threshold != skip_threshold:
            raise ValueError(
                f"Expected equal-threshold T={skip_threshold} in {path}"
            )
    else:
        recorded_skip = int(dewa_config.get("skip_threshold_bits", -1))
        recorded_replace = int(dewa_config.get("replace_threshold_bits", -1))
        if (recorded_skip, recorded_replace) != (
            skip_threshold,
            replace_threshold,
        ):
            raise ValueError(
                f"Expected (Tskip, Treplace)=({skip_threshold}, "
                f"{replace_threshold}) in {path}"
            )
        if "exception_threshold_bits" in dewa_config:
            raise ValueError(f"Unexpected legacy exception threshold in {path}")

    fp16_reference = float(payload.get("fp16_baseline_perplexity", np.nan))
    if not np.isclose(
        fp16_reference,
        float(baseline["perplexity"]),
        rtol=0.0,
        atol=1e-12,
    ):
        raise ValueError(f"FP16 baseline mismatch in {path}")

    point_top2_baseline = float(payload.get("top2_baseline_perplexity", np.nan))
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
    return (
        DesignPoint(
            skip_threshold=skip_threshold,
            replace_threshold=replace_threshold,
            perplexity=perplexity,
            path=path,
        ),
        top2_baseline,
    )


def discover_design_points(
    experiments_root: Path,
    baseline: dict[str, Any],
) -> tuple[float, list[DesignPoint]]:
    points: list[DesignPoint] = []
    top2_baseline: float | None = None
    for skip_threshold, replace_threshold in DESIGN_POINTS:
        point, top2_baseline = load_design_point(
            result_path(experiments_root, skip_threshold, replace_threshold),
            skip_threshold,
            replace_threshold,
            baseline,
            top2_baseline,
        )
        points.append(point)
    if top2_baseline is None:
        raise ValueError("No valid Hybrid design points were found")
    if len(points) != len(DESIGN_POINTS):
        raise ValueError("Hybrid design-point count mismatch")
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
    ax.grid(axis="y", color="0.87", linewidth=0.45, linestyle="-", zorder=0)
    ax.spines["top"].set_visible(False)
    ax.spines["right"].set_visible(False)
    ax.tick_params(direction="in", top=False, right=False)


def plot_design_points(
    top2_baseline: float,
    points: list[DesignPoint],
    output_dir: Path,
) -> Path:
    x = np.arange(len(points), dtype=np.float64)
    delta_ppl = np.asarray(
        [point.perplexity - top2_baseline for point in points],
        dtype=np.float64,
    )
    tick_labels = [
        f"$({point.skip_threshold}, {point.replace_threshold})$"
        for point in points
    ]

    fig, ax = plt.subplots(figsize=(3.85, 2.32))
    ax.plot(
        x,
        delta_ppl,
        color="#E15759",
        linewidth=1.25,
        linestyle="-",
        zorder=3,
    )
    ax.scatter(
        x,
        delta_ppl,
        color="#E15759",
        marker="s",
        s=24,
        edgecolor="0.20",
        linewidth=0.55,
        zorder=4,
    )
    ax.axhline(
        0.0,
        color="0.38",
        linewidth=0.8,
        linestyle=(0, (4, 2)),
        zorder=1,
    )
    ax.set_xlabel(r"$(T_{\mathrm{skip}}, T_{\mathrm{replace}})$")
    ax.set_ylabel(r"$\Delta$PPL from Top-2 A-BiE4")
    ax.set_xticks(x)
    ax.set_xticklabels(tick_labels, rotation=40, ha="right")
    ax.set_xlim(float(x.min()) - 0.25, float(x.max()) + 0.25)
    ax.set_ylim(-0.003, 0.060)
    ax.set_yticks(np.arange(0.0, 0.0601, 0.010))
    ax.yaxis.set_major_formatter(FormatStrFormatter("%.2f"))
    style_axes(ax)
    ax.tick_params(axis="x", direction="out", pad=1.5)
    ax.text(
        0.98,
        0.95,
        "Top-2 A-BiE4 baseline",
        transform=ax.transAxes,
        ha="right",
        va="top",
        fontsize=7,
        color="0.30",
    )

    output_dir.mkdir(parents=True, exist_ok=True)
    output_path = output_dir / "hybrid_tskip_treplace_delta_ppl.png"
    fig.tight_layout(pad=0.35)
    fig.savefig(output_path, dpi=600, bbox_inches="tight")
    fig.savefig(output_path.with_suffix(".pdf"), bbox_inches="tight")
    plt.close(fig)
    return output_path


def main() -> None:
    script_path = Path(__file__).resolve()
    research_root = script_path.parents[2]
    parser = argparse.ArgumentParser(
        description=(
            "Plot selected Hybrid (Tskip, Treplace) PPL points for LLaMA-2-7B."
        )
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
    top2_baseline, points = discover_design_points(
        args.experiments_root,
        baseline,
    )
    output_dir = (
        args.output_dir
        if args.output_dir is not None
        else script_path.parent / "figures" / "g16"
    )

    configure_ieee_style()
    print(f"Top-2 baseline: PPL={top2_baseline:.6f}")
    for point in points:
        delta = point.perplexity - top2_baseline
        print(
            f"({point.skip_threshold}, {point.replace_threshold}): "
            f"PPL={point.perplexity:.6f}; Delta Top-2={delta:+.6f}"
        )
    print(
        "Saved: "
        + str(plot_design_points(top2_baseline, points, output_dir))
    )


if __name__ == "__main__":
    main()
