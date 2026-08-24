"""Plot the PPL impact of the direct-FP-ACC asymmetric DEWA sweep."""

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
from matplotlib.ticker import FormatStrFormatter


SKIP_THRESHOLD = 9
SYMMETRIC_REFERENCE_THRESHOLD = 9
EXPECTED_REPLACE_THRESHOLDS = tuple(range(2, 9))
RESULT_PATTERN = re.compile(
    r"w-bfp4-a-bie4-top2cap-asym-dewa-fpacc-tskip9-"
    r"treplace(?P<replace_threshold>\d+)-s2048\.json"
)


@dataclass(frozen=True)
class SweepPoint:
    """One validated direct-FP-ACC asymmetric DEWA measurement."""

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


def discover_asymmetric_sweep(
    experiments_root: Path,
    baseline: dict[str, Any],
) -> tuple[float, dict[int, SweepPoint]]:
    """Load the Tskip=9, direct-exception-FP-ACC Treplace=2...8 sweep."""
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

        replace_threshold = int(match.group("replace_threshold"))
        if replace_threshold not in EXPECTED_REPLACE_THRESHOLDS:
            continue

        payload = load_json(path)
        hybrid_config = payload.get("hybrid_config")
        dewa_config = payload.get("dewa_config")
        routing_contract = payload.get("routing_contract")
        if (
            not isinstance(hybrid_config, dict)
            or not isinstance(dewa_config, dict)
            or not isinstance(routing_contract, dict)
        ):
            raise ValueError(f"Missing Hybrid/DEWA routing configuration in {path}")

        if int(hybrid_config.get("block_size", -1)) != 16:
            raise ValueError(f"Expected Group-16 configuration in {path}")
        if 1 + int(hybrid_config.get("mantissa_bits", -1)) != 4:
            raise ValueError(f"Expected BFP4/BiE4 mantissa format in {path}")
        if bool(hybrid_config.get("quantize_lm_head", True)):
            raise ValueError(f"LM head must remain FP16 in {path}")
        if int(hybrid_config.get("max_outliers_per_block", -1)) != 2:
            raise ValueError(f"Expected Top-2 activation cap in {path}")

        if int(dewa_config.get("skip_threshold_bits", -1)) != SKIP_THRESHOLD:
            raise ValueError(f"Expected Tskip={SKIP_THRESHOLD} in {path}")
        if (
            int(dewa_config.get("replace_threshold_bits", -1))
            != replace_threshold
        ):
            raise ValueError(f"Expected Treplace={replace_threshold} in {path}")
        if "exception_threshold_bits" in dewa_config:
            raise ValueError(f"Unexpected legacy exception threshold in {path}")
        if (
            routing_contract.get("exception_destination")
            != "every nonzero exception partial goes directly to shared FP32 FP-ACC"
        ):
            raise ValueError(f"Expected direct exception FP-ACC routing in {path}")

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
        points[replace_threshold] = SweepPoint(
            replace_threshold=replace_threshold,
            perplexity=perplexity,
            path=path,
        )

    missing = sorted(set(EXPECTED_REPLACE_THRESHOLDS) - set(points))
    if missing:
        raise ValueError(f"Missing replacement-threshold results: {missing}")
    if top2_baseline is None:
        raise ValueError("No valid asymmetric Hybrid results were found")
    return top2_baseline, points


def discover_symmetric_reference(
    experiments_root: Path,
    baseline: dict[str, Any],
    top2_baseline: float,
) -> float:
    """Load the archived symmetric T=9 endpoint for the displayed sweep."""
    path = (
        experiments_root
        / "09_Hybrid"
        / "llama2-7b"
        / (
            "w-bfp4-a-bie4-top2cap-dewa-fpacc-excskip-"
            f"t{SYMMETRIC_REFERENCE_THRESHOLD}-s2048.json"
        )
    )
    if not path.is_file():
        raise FileNotFoundError(f"Symmetric reference result not found: {path}")

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

    reference_threshold = SYMMETRIC_REFERENCE_THRESHOLD
    if int(dewa_config.get("threshold_bits", -1)) != reference_threshold:
        raise ValueError(f"Expected symmetric T={reference_threshold} in {path}")
    if int(dewa_config.get("exception_threshold_bits", -1)) != reference_threshold:
        raise ValueError(
            f"Expected exception threshold T={reference_threshold} in {path}"
        )
    if not bool(dewa_config.get("exception_skip_enabled", False)):
        raise ValueError(f"Expected conditional exception skip in {path}")

    validate_protocol(payload, baseline, path)
    fp16_reference = float(payload.get("fp16_baseline_perplexity", np.nan))
    if not np.isclose(
        fp16_reference,
        float(baseline["perplexity"]),
        rtol=0.0,
        atol=1e-12,
    ):
        raise ValueError(f"FP16 baseline mismatch in {path}")
    reference_top2_baseline = float(
        payload.get("top2_baseline_perplexity", np.nan)
    )
    if not np.isclose(
        reference_top2_baseline,
        top2_baseline,
        rtol=0.0,
        atol=1e-12,
    ):
        raise ValueError(f"Top-2 baseline mismatch in {path}")

    perplexity = float(payload.get("perplexity", np.nan))
    if not np.isfinite(perplexity) or perplexity <= 0.0:
        raise ValueError(f"Invalid PPL in {path}")
    return perplexity


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


def plot_asymmetric_sweep(
    top2_baseline: float,
    symmetric_reference_ppl: float,
    points: dict[int, SweepPoint],
    output_dir: Path,
) -> Path:
    thresholds = np.asarray(
        (*EXPECTED_REPLACE_THRESHOLDS, SYMMETRIC_REFERENCE_THRESHOLD),
        dtype=np.int64,
    )
    perplexities = np.asarray(
        [
            *[
                points[int(threshold)].perplexity
                for threshold in EXPECTED_REPLACE_THRESHOLDS
            ],
            symmetric_reference_ppl,
        ],
        dtype=np.float64,
    )
    delta_ppl = perplexities - top2_baseline

    fig, ax = plt.subplots(figsize=(3.5, 2.28))
    ax.plot(
        thresholds,
        delta_ppl,
        color="#E15759",
        linewidth=1.25,
        linestyle="-",
        zorder=3,
    )
    ax.scatter(
        thresholds[:-1],
        delta_ppl[:-1],
        color="#E15759",
        marker="s",
        s=24,
        edgecolor="0.20",
        linewidth=0.55,
        zorder=4,
    )
    ax.scatter(
        thresholds[-1:],
        delta_ppl[-1:],
        color="#E15759",
        marker="o",
        s=25,
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
    ax.set_xlabel(r"DEWA positive-side threshold, $T$")
    ax.set_ylabel(r"$\Delta$PPL from Top-2 A-BiE4")
    ax.set_xticks(thresholds)
    ax.set_xlim(float(thresholds.min()) - 0.2, float(thresholds.max()) + 0.2)
    ax.set_ylim(-0.0015, max(0.04, float(delta_ppl.max()) * 1.16))
    ax.set_yticks(np.arange(0.0, 0.0401, 0.005))
    ax.yaxis.set_major_formatter(FormatStrFormatter("%.3f"))
    style_axes(ax)
    ax.text(
        0.98,
        0.95,
        "$T=2$--$8$: asymmetric\n$T=9$: symmetric",
        transform=ax.transAxes,
        ha="right",
        va="top",
        fontsize=7,
    )
    ax.text(
        0.98,
        0.055,
        "Top-2 A-BiE4 baseline",
        transform=ax.transAxes,
        ha="right",
        va="bottom",
        fontsize=7,
        color="0.30",
    )

    output_dir.mkdir(parents=True, exist_ok=True)
    output_path = output_dir / "hybrid_asymmetric_tskip9_delta_ppl.png"
    fig.tight_layout(pad=0.35)
    fig.savefig(output_path, dpi=600, bbox_inches="tight")
    fig.savefig(output_path.with_suffix(".pdf"), bbox_inches="tight")
    plt.close(fig)
    return output_path


def main() -> None:
    script_path = Path(__file__).resolve()
    research_root = script_path.parents[2]
    parser = argparse.ArgumentParser(
        description="Plot the BFP4 Tskip=9 asymmetric DEWA PPL sweep."
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
    top2_baseline, points = discover_asymmetric_sweep(
        args.experiments_root,
        baseline,
    )
    symmetric_reference_ppl = discover_symmetric_reference(
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
        point = points[threshold]
        print(
            f"Treplace={threshold}: PPL={point.perplexity:.6f}; "
            f"Delta Top-2={point.perplexity - top2_baseline:+.6f}"
        )
    print(
        f"Symmetric T={SYMMETRIC_REFERENCE_THRESHOLD}: "
        f"PPL={symmetric_reference_ppl:.6f}; "
        f"Delta Top-2={symmetric_reference_ppl - top2_baseline:+.6f}"
    )
    print(
        "Saved: "
        + str(
            plot_asymmetric_sweep(
                top2_baseline,
                symmetric_reference_ppl,
                points,
                output_dir,
            )
        )
    )


if __name__ == "__main__":
    main()
