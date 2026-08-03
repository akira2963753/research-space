"""Plot BFP and BiE-family PPL degradation."""

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


FORMATS = tuple(range(4, 9))
HYBRID_THRESHOLDS = tuple(range(8, 13))
HYBRID_FILE_PATTERN = re.compile(
    r"w-bfp4-a-bie4-top2cap-dewa-fpacc-excskip-t(?P<threshold>\d+)-s2048\.json"
)


@dataclass(frozen=True)
class MethodSpec:
    """Result directory, config key, and visual identity for one method."""

    label: str
    relative_dir: Path
    config_key: str
    color: str
    marker: str
    linestyle: str


@dataclass(frozen=True)
class ResultPoint:
    """One validated PPL measurement."""

    bits: int
    perplexity: float
    quantize_lm_head: bool
    path: Path


@dataclass(frozen=True)
class HybridResultPoint:
    """One validated Top-2 + DEWA hybrid threshold result."""

    threshold: int
    perplexity: float
    path: Path


METHODS = (
    MethodSpec(
        label="BFP",
        relative_dir=Path("02_Vanilla_BFP") / "llama2-7b",
        config_key="bfp_config",
        color="#4C78A8",
        marker="o",
        linestyle="-",
    ),
    MethodSpec(
        label="BiE",
        relative_dir=Path("06_BiE") / "llama2-7b",
        config_key="bie_config",
        color="#D17C2F",
        marker="s",
        linestyle="-",
    ),
    MethodSpec(
        label="Activation BiE",
        relative_dir=Path("07_ActivationBiE") / "llama2-7b",
        config_key="hybrid_config",
        color="#59A14F",
        marker="^",
        linestyle="-",
    ),
    MethodSpec(
        label="Activation BiE Top-2",
        relative_dir=Path("08_ActivationBiETop2") / "llama2-7b",
        config_key="hybrid_config",
        color="#B279A2",
        marker="v",
        linestyle="-",
    ),
)


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


def discover_method_results(
    experiments_root: Path,
    spec: MethodSpec,
    group_size: int,
    baseline: dict[str, Any],
) -> dict[int, ResultPoint]:
    """Discover available formats and prefer a no-LM-Head result when duplicated."""
    result_dir = experiments_root / spec.relative_dir
    candidates: dict[int, list[ResultPoint]] = {}

    for path in sorted(result_dir.rglob("*.json")):
        payload = load_json(path)
        config = payload.get(spec.config_key)
        if not isinstance(config, dict):
            continue
        if int(config.get("block_size", -1)) != group_size:
            continue

        bits = 1 + int(config.get("mantissa_bits", -1))
        if bits not in FORMATS:
            continue
        validate_protocol(payload, baseline, path)

        reference = float(payload.get("baseline_perplexity", np.nan))
        baseline_ppl = float(baseline["perplexity"])
        if not np.isclose(reference, baseline_ppl, rtol=0.0, atol=1e-12):
            raise ValueError(f"FP16 baseline mismatch in {path}")

        perplexity = float(payload["perplexity"])
        if not np.isfinite(perplexity) or perplexity <= 0.0:
            raise ValueError(f"Invalid perplexity in {path}")

        candidates.setdefault(bits, []).append(
            ResultPoint(
                bits=bits,
                perplexity=perplexity,
                quantize_lm_head=bool(config.get("quantize_lm_head", False)),
                path=path,
            )
        )

    selected: dict[int, ResultPoint] = {}
    for bits, points in candidates.items():
        points.sort(key=lambda point: (point.quantize_lm_head, str(point.path)))
        preferred_scope = points[0].quantize_lm_head
        same_scope = [
            point for point in points if point.quantize_lm_head == preferred_scope
        ]
        if len(same_scope) > 1:
            paths = ", ".join(str(point.path) for point in same_scope)
            raise ValueError(f"Ambiguous {spec.label}{bits} results: {paths}")
        selected[bits] = points[0]
    return selected


def discover_hybrid_results(
    experiments_root: Path,
    group_size: int,
    baseline: dict[str, Any],
    top2_point: ResultPoint,
) -> dict[int, HybridResultPoint]:
    """Load and validate the BFP4/BiE4 Top-2 + DEWA T sweep."""
    result_dir = experiments_root / "09_Hybrid" / "llama2-7b"
    results: dict[int, HybridResultPoint] = {}
    baseline_ppl = float(baseline["perplexity"])

    for path in sorted(result_dir.glob("*.json")):
        match = HYBRID_FILE_PATTERN.fullmatch(path.name)
        if match is None:
            continue
        threshold = int(match.group("threshold"))
        if threshold not in HYBRID_THRESHOLDS:
            continue

        payload = load_json(path)
        validate_protocol(payload, baseline, path)
        config = payload.get("hybrid_config")
        dewa_config = payload.get("dewa_config")
        if not isinstance(config, dict) or not isinstance(dewa_config, dict):
            raise ValueError(f"Missing hybrid/DEWA configuration in {path}")

        if int(config.get("block_size", -1)) != group_size:
            continue
        if 1 + int(config.get("mantissa_bits", -1)) != 4:
            raise ValueError(f"Expected the BFP4/BiE4 hybrid format in {path}")
        if bool(config.get("quantize_lm_head", True)):
            raise ValueError(f"Hybrid LM Head must remain FP16 in {path}")
        if int(dewa_config.get("threshold_bits", -1)) != threshold:
            raise ValueError(f"Filename/DEWA threshold mismatch in {path}")
        if int(dewa_config.get("exception_threshold_bits", -1)) != threshold:
            raise ValueError(f"Filename/exception threshold mismatch in {path}")

        fp16_reference = float(payload.get("fp16_baseline_perplexity", np.nan))
        top2_reference = float(payload.get("top2_baseline_perplexity", np.nan))
        if not np.isclose(fp16_reference, baseline_ppl, rtol=0.0, atol=1e-12):
            raise ValueError(f"FP16 baseline mismatch in {path}")
        if not np.isclose(
            top2_reference,
            top2_point.perplexity,
            rtol=0.0,
            atol=1e-12,
        ):
            raise ValueError(f"Top-2 baseline mismatch in {path}")

        perplexity = float(payload["perplexity"])
        if not np.isfinite(perplexity) or perplexity <= 0.0:
            raise ValueError(f"Invalid perplexity in {path}")
        if threshold in results:
            raise ValueError(f"Duplicate hybrid T={threshold} result")
        results[threshold] = HybridResultPoint(
            threshold=threshold,
            perplexity=perplexity,
            path=path,
        )

    if results and set(results) != set(HYBRID_THRESHOLDS):
        missing = sorted(set(HYBRID_THRESHOLDS) - set(results))
        extra = sorted(set(results) - set(HYBRID_THRESHOLDS))
        raise ValueError(f"Incomplete hybrid sweep: missing={missing}, extra={extra}")
    return results


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
            "savefig.facecolor": "white",
        }
    )


def plot_delta_ppl(
    baseline_ppl: float,
    series: dict[str, dict[int, ResultPoint]],
    output_dir: Path,
) -> None:
    x = np.arange(len(FORMATS), dtype=np.float64)
    finite_values: list[float] = []

    fig, ax = plt.subplots(figsize=(3.5, 2.35))
    for spec in METHODS:
        values = np.full(len(FORMATS), np.nan, dtype=np.float64)
        for index, bits in enumerate(FORMATS):
            point = series[spec.label].get(bits)
            if point is not None:
                values[index] = point.perplexity - baseline_ppl
                finite_values.append(float(values[index]))

        ax.plot(
            x,
            values,
            color=spec.color,
            linewidth=1.2,
            linestyle=spec.linestyle,
            marker=spec.marker,
            markersize=4.0,
            markerfacecolor=spec.color,
            markeredgecolor="0.20",
            markeredgewidth=0.55,
            label=spec.label,
            zorder=3,
        )

    if not finite_values:
        raise ValueError("No PPL results were discovered")

    ax.set_xlabel("Data Format")
    ax.set_ylabel(r"$\Delta$PPL (vs. FP16)")
    ax.set_xticks(x, [f"BFP{bits}" for bits in FORMATS])
    ax.set_xlim(-0.18, len(FORMATS) - 0.82)
    ax.yaxis.set_major_locator(MaxNLocator(nbins=5))
    ax.grid(axis="y", color="0.84", linewidth=0.55, linestyle="--", zorder=0)
    ax.spines["top"].set_visible(False)
    ax.spines["right"].set_visible(False)
    ax.tick_params(direction="in", top=False, right=False)
    ax.legend(frameon=False, loc="upper right", handlelength=2.0)

    minimum = min(finite_values)
    maximum = max(finite_values)
    lower = min(0.0, minimum)
    margin = max(0.03, 0.10 * (maximum - lower))
    ax.set_ylim(lower - (margin if lower < 0.0 else 0.0), maximum + margin)

    output_dir.mkdir(parents=True, exist_ok=True)
    output_path = output_dir / "ppl_delta_comparison.png"
    fig.tight_layout(pad=0.35)
    fig.savefig(output_path, dpi=600, bbox_inches="tight")
    plt.close(fig)
    print(f"Saved: {output_path}")


def plot_delta_ppl_with_hybrid(
    baseline_ppl: float,
    series: dict[str, dict[int, ResultPoint]],
    hybrid_results: dict[int, HybridResultPoint],
    output_dir: Path,
) -> None:
    """Plot format comparison and the BFP4/BiE4 hybrid T sweep as two panels."""
    if not hybrid_results:
        return

    format_positions = np.arange(len(FORMATS), dtype=np.float64)
    format_values: list[float] = []
    fig, (format_ax, hybrid_ax) = plt.subplots(
        1,
        2,
        figsize=(7.16, 2.35),
        gridspec_kw={"width_ratios": (1.9, 1.0)},
    )

    for spec in METHODS:
        values = np.full(len(FORMATS), np.nan, dtype=np.float64)
        for index, bits in enumerate(FORMATS):
            point = series[spec.label].get(bits)
            if point is not None:
                values[index] = point.perplexity - baseline_ppl
                format_values.append(float(values[index]))

        format_ax.plot(
            format_positions,
            values,
            color=spec.color,
            linewidth=1.2,
            linestyle=spec.linestyle,
            marker=spec.marker,
            markersize=4.0,
            markerfacecolor=spec.color,
            markeredgecolor="0.20",
            markeredgewidth=0.55,
            label=spec.label,
            zorder=3,
        )

    format_ax.set_xlabel("Data Format")
    format_ax.set_ylabel(r"$\Delta$PPL (vs. FP16)")
    format_ax.set_xticks(format_positions, [f"BFP{bits}" for bits in FORMATS])
    format_ax.set_xlim(-0.18, len(FORMATS) - 0.82)
    format_ax.yaxis.set_major_locator(MaxNLocator(nbins=5))
    format_ax.grid(
        axis="y",
        color="0.84",
        linewidth=0.55,
        linestyle="--",
        zorder=0,
    )
    format_ax.spines["top"].set_visible(False)
    format_ax.spines["right"].set_visible(False)
    format_ax.tick_params(direction="in", top=False, right=False)
    format_ax.legend(frameon=False, loc="upper right", handlelength=2.0)
    format_ax.text(
        -0.10,
        1.015,
        "(a)",
        transform=format_ax.transAxes,
        ha="left",
        va="bottom",
        clip_on=False,
    )

    format_minimum = min(format_values)
    format_maximum = max(format_values)
    format_lower = min(0.0, format_minimum)
    format_margin = max(0.03, 0.10 * (format_maximum - format_lower))
    format_ax.set_ylim(
        format_lower - (format_margin if format_lower < 0.0 else 0.0),
        format_maximum + format_margin,
    )

    thresholds = np.asarray(sorted(hybrid_results), dtype=np.int64)
    hybrid_delta = np.asarray(
        [
            hybrid_results[int(threshold)].perplexity - baseline_ppl
            for threshold in thresholds
        ],
        dtype=np.float64,
    )
    top2_point = series["Activation BiE Top-2"][4]
    top2_delta = top2_point.perplexity - baseline_ppl
    hybrid_color = "#E15759"

    hybrid_ax.plot(
        thresholds,
        hybrid_delta,
        color=hybrid_color,
        linewidth=1.25,
        linestyle="-",
        marker="o",
        markersize=4.2,
        markerfacecolor=hybrid_color,
        markeredgecolor="0.20",
        markeredgewidth=0.55,
        label="Hybrid",
        zorder=3,
    )
    hybrid_ax.axhline(
        top2_delta,
        color="0.45",
        linewidth=0.9,
        linestyle="-",
        label="Top-2 baseline",
        zorder=1,
    )
    t9_index = int(np.where(thresholds == 9)[0][0])
    hybrid_ax.annotate(
        "T9 knee",
        xy=(9, hybrid_delta[t9_index]),
        xytext=(9.35, hybrid_delta[t9_index] + 0.018),
        arrowprops={"arrowstyle": "-", "color": "0.35", "linewidth": 0.6},
        ha="left",
        va="center",
        fontsize=7,
    )

    hybrid_ax.set_xlabel("DEWA Threshold (T)")
    hybrid_ax.set_ylabel(r"$\Delta$PPL (vs. FP16)")
    hybrid_ax.set_xticks(thresholds)
    hybrid_ax.set_xlim(thresholds[0] - 0.25, thresholds[-1] + 0.25)
    hybrid_ax.yaxis.set_major_locator(MaxNLocator(nbins=5))
    hybrid_ax.grid(
        axis="y",
        color="0.84",
        linewidth=0.55,
        linestyle="--",
        zorder=0,
    )
    hybrid_ax.spines["top"].set_visible(False)
    hybrid_ax.spines["right"].set_visible(False)
    hybrid_ax.tick_params(direction="in", top=False, right=False)
    hybrid_ax.legend(frameon=False, loc="upper right", handlelength=1.8)
    hybrid_ax.text(
        -0.19,
        1.015,
        "(b)",
        transform=hybrid_ax.transAxes,
        ha="left",
        va="bottom",
        clip_on=False,
    )

    hybrid_range = max(hybrid_delta.max(), top2_delta) - min(
        hybrid_delta.min(),
        top2_delta,
    )
    hybrid_margin = max(0.004, 0.08 * hybrid_range)
    hybrid_ax.set_ylim(
        min(hybrid_delta.min(), top2_delta) - hybrid_margin,
        max(hybrid_delta.max(), top2_delta) + hybrid_margin,
    )

    output_dir.mkdir(parents=True, exist_ok=True)
    output_path = output_dir / "ppl_delta_comparison_with_hybrid.png"
    fig.tight_layout(pad=0.35, w_pad=1.2)
    fig.savefig(output_path, dpi=600, bbox_inches="tight")
    plt.close(fig)
    print(f"Saved: {output_path}")


def print_summary(
    baseline_ppl: float,
    series: dict[str, dict[int, ResultPoint]],
) -> None:
    print(f"FP16 baseline PPL: {baseline_ppl:.6f}")
    print("Method          Format  PPL       Delta PPL  LM Head")
    for spec in METHODS:
        for bits in FORMATS:
            point = series[spec.label].get(bits)
            if point is None:
                continue
            print(
                f"{spec.label:<15} BFP{bits:<2}   {point.perplexity:>8.6f}  "
                f"{point.perplexity - baseline_ppl:>9.6f}  "
                f"{'quantized' if point.quantize_lm_head else 'FP16'}"
            )

    scopes = {
        (spec.label, point.quantize_lm_head)
        for spec in METHODS
        for point in series[spec.label].values()
    }
    if len({scope for _, scope in scopes}) > 1:
        print(
            "Warning: available methods do not use the same LM Head scope; "
            "the current figure is provisional."
        )


def print_hybrid_summary(
    baseline_ppl: float,
    top2_point: ResultPoint,
    results: dict[int, HybridResultPoint],
) -> None:
    if not results:
        return

    print("Hybrid threshold sweep (BFP4/BiE4 Top-2 + DEWA)")
    print("T   PPL       Delta FP16  Delta Top-2")
    for threshold in sorted(results):
        point = results[threshold]
        print(
            f"{threshold:<2}  {point.perplexity:>8.6f}  "
            f"{point.perplexity - baseline_ppl:>10.6f}  "
            f"{point.perplexity - top2_point.perplexity:>11.6f}"
        )


def main() -> None:
    script_path = Path(__file__).resolve()
    research_root = script_path.parents[2]
    parser = argparse.ArgumentParser(
        description="Plot BFP, BiE, activation-BiE, and Top-2 delta PPL."
    )
    parser.add_argument("--group-size", type=int, default=16)
    parser.add_argument(
        "--experiments-root",
        type=Path,
        default=research_root / "experiments",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=None,
    )
    args = parser.parse_args()
    if args.group_size <= 0:
        raise ValueError("--group-size must be positive")

    baseline_path = (
        args.experiments_root / "01_Baseline" / "llama2-7b" / "baseline.json"
    )
    baseline = load_json(baseline_path)
    baseline_ppl = float(baseline["perplexity"])
    series = {
        spec.label: discover_method_results(
            args.experiments_root,
            spec,
            args.group_size,
            baseline,
        )
        for spec in METHODS
    }
    top2_point = series["Activation BiE Top-2"].get(4)
    if top2_point is None:
        raise ValueError("Missing the BFP4/BiE4 Top-2 baseline")
    hybrid_results = discover_hybrid_results(
        args.experiments_root,
        args.group_size,
        baseline,
        top2_point,
    )
    output_dir = (
        args.output_dir
        if args.output_dir is not None
        else script_path.parent / "figures" / f"g{args.group_size}"
    )

    configure_ieee_style()
    print_summary(baseline_ppl, series)
    print_hybrid_summary(baseline_ppl, top2_point, hybrid_results)
    plot_delta_ppl(baseline_ppl, series, output_dir)
    plot_delta_ppl_with_hybrid(
        baseline_ppl,
        series,
        hybrid_results,
        output_dir,
    )


if __name__ == "__main__":
    main()
