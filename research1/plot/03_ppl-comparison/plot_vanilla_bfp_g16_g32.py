"""Plot four-model Vanilla-BFP PPL degradation for Group-16 and Group-32."""

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
from matplotlib.ticker import MultipleLocator


BITS = tuple(range(4, 9))
GROUP_SIZES = (16, 32)


@dataclass(frozen=True)
class ModelSpec:
    """One evaluated model and its stable visual identity."""

    directory: str
    label: str
    color: str
    marker: str


@dataclass(frozen=True)
class ResultPoint:
    """One validated Vanilla-BFP PPL result."""

    bits: int
    perplexity: float
    fp16_perplexity: float
    path: Path


MODELS = (
    ModelSpec("llama2-7b", "LLaMA-2-7B", "#4C78A8", "o"),
    ModelSpec("llama2-13b", "LLaMA-2-13B", "#F28E2B", "s"),
    ModelSpec("llama3.1-8b", "LLaMA-3.1-8B", "#59A14F", "^"),
    ModelSpec("opt-6.7b", "OPT-6.7B", "#B279A2", "P"),
)


def load_json(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as file:
        return json.load(file)


def validate_protocol(
    payload: dict[str, Any], baseline: dict[str, Any], path: Path
) -> None:
    """Ensure that the quantized result uses the baseline evaluation protocol."""
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


def find_single_result(directory: Path, bits: int, group_size: int) -> Path:
    matches = sorted(directory.glob(f"bfp{bits}-g{group_size}*.json"))
    if len(matches) != 1:
        raise ValueError(
            f"Expected exactly one BFP{bits}/G{group_size} result in {directory}; "
            f"found {len(matches)}"
        )
    return matches[0]


def discover_results(
    experiments_root: Path, spec: ModelSpec, group_size: int
) -> dict[int, ResultPoint]:
    """Load all BFP4--BFP8 points for one model and one group size."""
    baseline_path = experiments_root / "01_Baseline" / spec.directory / "baseline.json"
    baseline = load_json(baseline_path)
    fp16_perplexity = float(baseline["perplexity"])
    result_dir = experiments_root / "02_Vanilla_BFP" / spec.directory / f"g{group_size}"
    results: dict[int, ResultPoint] = {}

    for bits in BITS:
        path = find_single_result(result_dir, bits, group_size)
        payload = load_json(path)
        validate_protocol(payload, baseline, path)

        config = payload.get("bfp_config")
        if not isinstance(config, dict):
            raise ValueError(f"Missing BFP configuration in {path}")
        if int(config.get("block_size", -1)) != group_size:
            raise ValueError(f"Group-size mismatch in {path}")
        if 1 + int(config.get("mantissa_bits", -1)) != bits:
            raise ValueError(f"BFP format mismatch in {path}")
        if not bool(config.get("quantize_lm_head", False)):
            raise ValueError(f"Vanilla BFP must quantize the LM head in {path}")

        recorded_baseline = payload.get("baseline_perplexity")
        if recorded_baseline is not None and not np.isclose(
            float(recorded_baseline), fp16_perplexity, rtol=0.0, atol=1e-12
        ):
            raise ValueError(f"FP16 baseline mismatch in {path}")

        perplexity = float(payload["perplexity"])
        if not np.isfinite(perplexity) or perplexity <= 0.0:
            raise ValueError(f"Invalid perplexity in {path}")
        results[bits] = ResultPoint(bits, perplexity, fp16_perplexity, path)

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
            "mathtext.fontset": "stix",
            "pdf.fonttype": 42,
            "ps.fonttype": 42,
            "savefig.facecolor": "white",
        }
    )


def plot_results(
    results: dict[int, dict[str, dict[int, ResultPoint]]], output_dir: Path
) -> list[tuple[Path, Path]]:
    """Render separate Group-16 and Group-32 figures on one shared scale."""
    x = np.asarray(BITS, dtype=np.float64)
    deltas = [
        point.perplexity - point.fp16_perplexity
        for group_results in results.values()
        for model_results in group_results.values()
        for point in model_results.values()
    ]
    if not deltas:
        raise ValueError("No BFP results were found")

    lower = min(-0.10, min(deltas) - 0.06)
    upper = np.ceil((max(deltas) + 0.10) * 10.0) / 10.0

    output_dir.mkdir(parents=True, exist_ok=True)
    output_paths: list[tuple[Path, Path]] = []
    for group_size in GROUP_SIZES:
        fig, axis = plt.subplots(figsize=(3.5, 2.40))
        for spec in MODELS:
            model_results = results[group_size][spec.directory]
            y = np.asarray(
                [
                    model_results[bits].perplexity
                    - model_results[bits].fp16_perplexity
                    for bits in BITS
                ],
                dtype=np.float64,
            )
            axis.plot(
                x,
                y,
                color=spec.color,
                linewidth=1.25,
                marker=spec.marker,
                markersize=4.1,
                markerfacecolor=spec.color,
                markeredgecolor="0.20",
                markeredgewidth=0.55,
                label=spec.label,
                zorder=3,
            )

        axis.axhline(
            0.0,
            color="0.40",
            linewidth=0.85,
            linestyle="--",
            zorder=1,
        )
        axis.set_xticks(x, [f"BFP{bits}" for bits in BITS])
        axis.set_xlim(BITS[0] - 0.15, BITS[-1] + 0.15)
        axis.set_ylim(lower, upper)
        axis.yaxis.set_major_locator(MultipleLocator(0.5))
        axis.grid(axis="y", color="0.84", linewidth=0.55, linestyle="--", zorder=0)
        axis.spines["top"].set_visible(False)
        axis.spines["right"].set_visible(False)
        axis.tick_params(direction="in", top=False, right=False)
        axis.set_xlabel("BFP format")
        axis.set_ylabel(r"$\Delta$PPL (vs. FP16)")
        axis.text(
            0.02,
            0.96,
            f"Group size = {group_size}",
            transform=axis.transAxes,
            ha="left",
            va="top",
        )
        axis.legend(
            loc="upper right",
            ncol=2,
            frameon=True,
            fancybox=True,
            framealpha=0.92,
            facecolor="white",
            edgecolor="0.75",
            handlelength=1.65,
            columnspacing=0.75,
            labelspacing=0.26,
            borderpad=0.45,
            borderaxespad=0.35,
        )
        fig.tight_layout(pad=0.35)

        png_path = output_dir / f"vanilla_bfp_delta_ppl_g{group_size}.png"
        pdf_path = png_path.with_suffix(".pdf")
        fig.savefig(png_path, dpi=600, bbox_inches="tight")
        fig.savefig(pdf_path, bbox_inches="tight")
        plt.close(fig)
        output_paths.append((png_path, pdf_path))

    return output_paths


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Plot four-model Vanilla-BFP Delta-PPL results for G16 and G32."
    )
    default_root = Path(__file__).resolve().parents[2]
    parser.add_argument(
        "--experiments-root",
        type=Path,
        default=default_root / "experiments",
        help="Directory containing 01_Baseline and 02_Vanilla_BFP.",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=Path(__file__).resolve().parent / "figures" / "g16_g32",
        help="Directory for the PNG and vector-PDF figures.",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    configure_ieee_style()
    results = {
        group_size: {
            spec.directory: discover_results(args.experiments_root, spec, group_size)
            for spec in MODELS
        }
        for group_size in GROUP_SIZES
    }
    for png_path, pdf_path in plot_results(results, args.output_dir):
        print(f"Saved: {png_path}")
        print(f"Saved: {pdf_path}")
    print("\nModel           Group  BFP4    BFP5    BFP6    BFP7    BFP8")
    for spec in MODELS:
        for group_size in GROUP_SIZES:
            deltas = [
                results[group_size][spec.directory][bits].perplexity
                - results[group_size][spec.directory][bits].fp16_perplexity
                for bits in BITS
            ]
            print(
                f"{spec.label:<15} G{group_size:<3} "
                + " ".join(f"{delta:>7.3f}" for delta in deltas)
            )


if __name__ == "__main__":
    main()
