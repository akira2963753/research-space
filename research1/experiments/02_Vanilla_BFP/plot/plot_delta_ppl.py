#!/usr/bin/env python3
"""Plot BFP4-BFP8 perplexity deltas for the four evaluated models."""

from __future__ import annotations

import argparse
import json
import math
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import matplotlib as mpl
import matplotlib.pyplot as plt
import numpy as np
from matplotlib import font_manager
from matplotlib.ticker import FuncFormatter, MultipleLocator


SCRIPT_DIR = Path(__file__).resolve().parent
EXPERIMENT_DIR = SCRIPT_DIR.parent
DEFAULT_OUTPUT_DIR = SCRIPT_DIR / "figures"
DEFAULT_FONT = (
    EXPERIMENT_DIR.parent
    / "01_Baseline"
    / "llama2-7b"
    / "plot"
    / "fonts"
    / "EBGaramond-Bold.ttf"
)
BFP_BITS = (4, 5, 6, 7, 8)


@dataclass(frozen=True)
class ModelSpec:
    slug: str
    label: str
    color: str
    marker: str


MODEL_SPECS = (
    ModelSpec("llama2-7b", "LLaMA-2-7B", "#4C78A8", "o"),
    ModelSpec("llama2-13b", "LLaMA-2-13B", "#F28E2B", "s"),
    ModelSpec("llama3.1-8b", "LLaMA-3.1-8B", "#59A14F", "^"),
    ModelSpec("opt-6.7b", "OPT-6.7B", "#B07AA1", "P"),
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Plot BFP4-BFP8 ΔPPL versus the matching FP16 baseline."
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=DEFAULT_OUTPUT_DIR,
        help=f"Figure directory. Default: {DEFAULT_OUTPUT_DIR}",
    )
    parser.add_argument(
        "--font",
        type=Path,
        default=DEFAULT_FONT,
        help=f"EB Garamond Bold TTF. Default: {DEFAULT_FONT}",
    )
    parser.add_argument(
        "--png-dpi",
        type=int,
        default=600,
        help="PNG resolution. Default: 600.",
    )
    return parser.parse_args()


def configure_style(font_path: Path) -> font_manager.FontProperties:
    if not font_path.is_file():
        raise FileNotFoundError(
            f"EB Garamond Bold was not found at {font_path}. "
            "Pass --font PATH to a valid TTF file."
        )
    font_manager.fontManager.addfont(str(font_path))
    font_prop = font_manager.FontProperties(fname=str(font_path))
    mpl.rcParams.update(
        {
            "font.family": font_prop.get_name(),
            "font.weight": "bold",
            "axes.labelweight": "bold",
            "axes.linewidth": 1.3,
            "axes.edgecolor": "#202124",
            "xtick.color": "#202124",
            "ytick.color": "#202124",
            "text.color": "#202124",
            "figure.facecolor": "white",
            "axes.facecolor": "white",
            "savefig.facecolor": "white",
            "pdf.fonttype": 42,
            "ps.fonttype": 42,
            "savefig.bbox": "tight",
            "savefig.pad_inches": 0.05,
        }
    )
    return font_prop


def _result_path(spec: ModelSpec, bitwidth: int) -> Path:
    return (
        EXPERIMENT_DIR
        / spec.slug
        / "result"
        / f"bfp{bitwidth}-g16-rne-no-lm-head-s2048.json"
    )


def _read_result(path: Path, bitwidth: int) -> dict[str, Any]:
    if not path.is_file():
        raise FileNotFoundError(f"Missing BFP{bitwidth} result: {path}")
    with path.open("r", encoding="utf-8") as handle:
        data = json.load(handle)

    required = {"format", "perplexity", "baseline_perplexity", "delta_perplexity", "bfp_config"}
    missing = required.difference(data)
    if missing:
        raise ValueError(f"{path.name} is missing fields: {sorted(missing)}")
    if data["format"].split()[0] != f"BFP{bitwidth}":
        raise ValueError(f"{path.name} does not contain BFP{bitwidth} data")
    if int(data["bfp_config"]["mantissa_bits"]) != bitwidth - 1:
        raise ValueError(f"{path.name} has an incompatible mantissa width")

    perplexity = float(data["perplexity"])
    baseline = float(data["baseline_perplexity"])
    delta = float(data["delta_perplexity"])
    if not all(math.isfinite(value) for value in (perplexity, baseline, delta)):
        raise ValueError(f"{path.name} contains a non-finite PPL value")
    if not math.isclose(delta, perplexity - baseline, rel_tol=0.0, abs_tol=1e-6):
        raise ValueError(f"{path.name} has an inconsistent ΔPPL")
    return data


def collect_data() -> tuple[dict[str, list[float]], dict[str, list[str]]]:
    series: dict[str, list[float]] = {}
    source_files: dict[str, list[str]] = {}
    for spec in MODEL_SPECS:
        baselines: list[float] = []
        deltas: list[float] = []
        files: list[str] = []
        for bitwidth in BFP_BITS:
            path = _result_path(spec, bitwidth)
            data = _read_result(path, bitwidth)
            baselines.append(float(data["baseline_perplexity"]))
            deltas.append(float(data["delta_perplexity"]))
            files.append(str(path.resolve()))
        if not np.allclose(baselines, baselines[0], rtol=0.0, atol=1e-6):
            raise ValueError(f"{spec.label} uses inconsistent FP16 baseline PPL values")
        series[spec.slug] = deltas
        source_files[spec.slug] = files
    return series, source_files


def _y_limits(values: np.ndarray) -> tuple[float, float]:
    lower = min(-0.1, math.floor(float(values.min()) / 0.1) * 0.1)
    upper = max(0.5, math.ceil(float(values.max()) / 0.5) * 0.5)
    return lower, upper


def render(
    series: dict[str, list[float]],
    output_dir: Path,
    font_prop: font_manager.FontProperties,
    png_dpi: int,
) -> dict[str, str]:
    x = np.arange(len(BFP_BITS))
    all_values = np.asarray([value for values in series.values() for value in values])
    y_lower, y_upper = _y_limits(all_values)

    figure, axis = plt.subplots(figsize=(6.55, 4.65))
    for spec in MODEL_SPECS:
        axis.plot(
            x,
            series[spec.slug],
            label=spec.label,
            color=spec.color,
            marker=spec.marker,
            markersize=8.6,
            markeredgecolor="#404040",
            markeredgewidth=1.15,
            linewidth=2.45,
            solid_capstyle="round",
            zorder=3,
        )

    axis.axhline(0.0, color="#777777", linewidth=1.2, linestyle=(0, (4, 3)), zorder=1)
    axis.set_xlim(-0.08, len(BFP_BITS) - 0.92)
    axis.set_ylim(y_lower, y_upper + 0.05)
    axis.set_xticks(x, [f"BFP{bitwidth}" for bitwidth in BFP_BITS])
    axis.yaxis.set_major_locator(MultipleLocator(0.5))
    axis.yaxis.set_major_formatter(FuncFormatter(lambda value, _position: f"{value:.1f}"))
    axis.grid(axis="y", color="#D9D9D9", linewidth=1.0, linestyle="--", alpha=0.9, zorder=0)
    axis.spines["top"].set_visible(False)
    axis.spines["right"].set_visible(False)
    axis.tick_params(axis="both", which="major", width=1.25, length=5.5, direction="in")
    axis.set_xlabel("BFP format", fontsize=17, labelpad=10, fontproperties=font_prop)
    axis.set_ylabel("ΔPPL (vs. FP16)", fontsize=17, labelpad=10, fontproperties=font_prop)
    for label in (*axis.get_xticklabels(), *axis.get_yticklabels()):
        label.set_fontproperties(font_prop)
        label.set_fontsize(14)

    legend = axis.legend(
        loc="upper right",
        ncols=2,
        fontsize=13.8,
        frameon=True,
        framealpha=0.96,
        edgecolor="#C9C9C9",
        borderpad=0.42,
        columnspacing=1.15,
        handlelength=2.05,
        handletextpad=0.65,
    )
    legend.get_frame().set_linewidth(1.5)
    for label in legend.get_texts():
        label.set_fontproperties(font_prop)
    figure.subplots_adjust(left=0.14, right=0.985, bottom=0.15, top=0.965)

    output_dir.mkdir(parents=True, exist_ok=True)
    stem = "bfp4-bfp8_delta_ppl_vs_fp16"
    png_path = output_dir / f"{stem}.png"
    pdf_path = output_dir / f"{stem}.pdf"
    figure.savefig(png_path, dpi=png_dpi)
    figure.savefig(pdf_path)
    plt.close(figure)
    return {"png": str(png_path.resolve()), "pdf": str(pdf_path.resolve())}


def main() -> None:
    args = parse_args()
    font_prop = configure_style(args.font.resolve())
    series, source_files = collect_data()
    paths = render(series, args.output_dir.resolve(), font_prop, args.png_dpi)
    manifest = {
        "figure": "BFP4-BFP8 delta PPL versus matching FP16 baseline",
        "font": str(args.font.resolve()),
        "bitwidth_order": list(BFP_BITS),
        "series": {
            spec.label: {
                "delta_ppl": series[spec.slug],
                "result_json": source_files[spec.slug],
            }
            for spec in MODEL_SPECS
        },
        **paths,
    }
    manifest_path = args.output_dir.resolve() / "bfp4-bfp8_delta_ppl_vs_fp16_manifest.json"
    with manifest_path.open("w", encoding="utf-8") as handle:
        json.dump(manifest, handle, ensure_ascii=False, indent=2)
        handle.write("\n")
    print(f"Rendered: {paths['png']}")
    print(f"Rendered: {paths['pdf']}")
    print(f"Wrote manifest: {manifest_path}")


if __name__ == "__main__":
    main()
