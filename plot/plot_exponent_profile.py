"""Plot per-layer BFP partial-sum exponent profiles in an IEEE-ready style."""

from __future__ import annotations

import argparse
import json
import math
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import matplotlib
import numpy as np

matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.colors import BoundaryNorm, LinearSegmentedColormap, Normalize
from matplotlib.lines import Line2D
from matplotlib.patches import Patch
from matplotlib.ticker import MaxNLocator, PercentFormatter


DEFAULT_FORMATS = (8, 7, 6, 5, 4)
COVERAGES = (0.90, 0.95, 0.99)
LAYER_TYPES = (
    "q_proj",
    "k_proj",
    "v_proj",
    "o_proj",
    "gate_proj",
    "up_proj",
    "down_proj",
)
LAYER_TYPE_LABELS = (
    "Query (Q)",
    "Key (K)",
    "Value (V)",
    "Attention Output",
    "MLP Gate",
    "MLP Up",
    "MLP Down",
)
SELECTED_LAYERS = (
    ("L0: Query Projection", "model.layers.0.self_attn.q_proj"),
    ("L15: Attention Output Projection", "model.layers.15.self_attn.o_proj"),
    ("L31: MLP Down Projection", "model.layers.31.mlp.down_proj"),
    ("LM Head: Vocabulary Projection", "lm_head"),
)
FORMAT_COLORS = {
    8: "#4C78A8",
    7: "#D17C2F",
    6: "#59A14F",
    5: "#E15759",
    4: "#8064A2",
}
SEQUENTIAL_BLUES = (
    "#EFF3FF",
    "#C6DBEF",
    "#9ECAE1",
    "#6BAED6",
    "#4292C6",
    "#2171B5",
    "#084594",
)


@dataclass(frozen=True)
class LayerHistogram:
    """Validated exponent histogram for one Linear layer."""

    name: str
    layer_type: str
    layer_index: int
    exponents: np.ndarray
    counts: np.ndarray
    zero_partials: int
    total_partials: int

    @property
    def nonzero_partials(self) -> int:
        return int(self.counts.sum())

    @property
    def frequency_percent(self) -> np.ndarray:
        if self.nonzero_partials == 0:
            raise ValueError(f"No nonzero partial sums in {self.name}")
        return self.counts.astype(np.float64) * (100.0 / self.nonzero_partials)

    @property
    def zero_rate_percent(self) -> float:
        return 100.0 * self.zero_partials / self.total_partials


@dataclass(frozen=True)
class ProfileResult:
    """One BFP format and its per-layer exponent profiles."""

    bits: int
    group_size: int
    metadata: dict[str, Any]
    layers: dict[str, LayerHistogram]


@dataclass(frozen=True)
class CoverageWindow:
    """Shortest contiguous exponent interval meeting a target coverage."""

    span: int
    low: int
    high: int


def require(mapping: dict[str, Any], key: str, path: Path) -> Any:
    if key not in mapping:
        raise KeyError(f"Missing '{key}' in {path}")
    return mapping[key]


def load_profile(path: Path, bits: int, group_size: int) -> ProfileResult:
    """Load and validate one profiler JSON."""
    with path.open("r", encoding="utf-8") as file:
        payload = json.load(file)

    metadata = require(payload, "metadata", path)
    config = require(metadata, "bfp_config", path)
    if int(require(config, "block_size", path)) != group_size:
        raise ValueError(f"Unexpected block size in {path}")
    if 1 + int(require(config, "mantissa_bits", path)) != bits:
        raise ValueError(f"Unexpected BFP format in {path}")

    exp_min = int(require(metadata, "exp_bin_min", path))
    exp_max = int(require(metadata, "exp_bin_max", path))
    if exp_min > exp_max:
        raise ValueError(f"Invalid exponent range in {path}")
    exponents = np.arange(exp_min, exp_max + 1, dtype=np.int64)

    layers: dict[str, LayerHistogram] = {}
    for record in require(payload, "layers", path):
        name = str(require(record, "layer_name", path))
        if name in layers:
            raise ValueError(f"Duplicate layer '{name}' in {path}")

        counts = np.asarray(require(record, "counts", path), dtype=np.int64)
        if counts.shape != exponents.shape or np.any(counts < 0):
            raise ValueError(f"Invalid histogram for {name} in {path}")

        zero = int(require(record, "num_zero_partials", path))
        underflow = int(require(record, "num_underflow", path))
        overflow = int(require(record, "num_overflow", path))
        total = int(require(record, "total_partials", path))
        if min(zero, underflow, overflow, total) < 0:
            raise ValueError(f"Negative counter for {name} in {path}")
        if int(counts.sum()) + zero + underflow + overflow != total:
            raise ValueError(f"Histogram accounting mismatch for {name} in {path}")
        if underflow or overflow:
            raise ValueError(
                f"Guard bins are nonzero for {name} in {path}; coverage is incomplete."
            )

        layers[name] = LayerHistogram(
            name=name,
            layer_type=str(require(record, "layer_type", path)),
            layer_index=int(require(record, "layer_index", path)),
            exponents=exponents,
            counts=counts,
            zero_partials=zero,
            total_partials=total,
        )

    if not layers:
        raise ValueError(f"No layer profiles in {path}")
    return ProfileResult(bits=bits, group_size=group_size, metadata=metadata, layers=layers)


def load_results(
    profile_dir: Path,
    formats: tuple[int, ...],
    group_size: int,
) -> list[ProfileResult]:
    results = []
    for bits in formats:
        path = profile_dir / f"bfp{bits}-g{group_size}.json"
        if not path.exists():
            raise FileNotFoundError(f"Missing profiler result: {path}")
        results.append(load_profile(path, bits, group_size))

    reference_layers = set(results[0].layers)
    for result in results[1:]:
        if set(result.layers) != reference_layers:
            raise ValueError(f"Layer set differs for BFP{result.bits}")
    return results


def shortest_coverage_window(
    layer: LayerHistogram,
    coverage: float,
) -> CoverageWindow:
    """Find the minimum exponent span that covers the requested probability mass."""
    if not 0.0 < coverage <= 1.0:
        raise ValueError("coverage must be in (0, 1].")
    total = layer.nonzero_partials
    if total == 0:
        raise ValueError(f"No nonzero partial sums in {layer.name}")

    target = math.ceil(coverage * total)
    left = 0
    running = 0
    best: tuple[int, int, int] | None = None

    for right, count in enumerate(layer.counts):
        running += int(count)
        while left < right and running - int(layer.counts[left]) >= target:
            running -= int(layer.counts[left])
            left += 1
        if running >= target:
            candidate = (right - left, left, right)
            if best is None or candidate < best:
                best = candidate

    if best is None:
        raise RuntimeError(f"Unable to compute coverage for {layer.name}")
    span, low_index, high_index = best
    return CoverageWindow(
        span=span,
        low=int(layer.exponents[low_index]),
        high=int(layer.exponents[high_index]),
    )


def compute_coverages(
    results: list[ProfileResult],
) -> dict[int, dict[float, dict[str, CoverageWindow]]]:
    return {
        result.bits: {
            coverage: {
                name: shortest_coverage_window(layer, coverage)
                for name, layer in result.layers.items()
            }
            for coverage in COVERAGES
        }
        for result in results
    }


def observed_full_span(layer: LayerHistogram) -> int:
    """Return Emax - Emin across all observed nonzero partial sums."""
    occupied = np.flatnonzero(layer.counts)
    if occupied.size == 0:
        raise ValueError(f"No nonzero partial sums in {layer.name}")
    return int(layer.exponents[occupied[-1]] - layer.exponents[occupied[0]])


def build_transformer_matrices(
    results: list[ProfileResult],
    values: dict[int, dict[str, int]],
) -> dict[int, np.ndarray]:
    """Arrange every Transformer Linear layer by projection type and block index."""
    matrices: dict[int, np.ndarray] = {}
    for result in results:
        matrix = np.full((len(LAYER_TYPES), 32), np.nan, dtype=np.float64)
        for layer in result.layers.values():
            if layer.layer_type in LAYER_TYPES and 0 <= layer.layer_index < 32:
                row = LAYER_TYPES.index(layer.layer_type)
                matrix[row, layer.layer_index] = values[result.bits][layer.name]
        if np.isnan(matrix).any():
            raise ValueError(f"Incomplete Transformer-layer heatmap for BFP{result.bits}")
        matrices[result.bits] = matrix
    return matrices


def configure_ieee_style() -> None:
    """Use compact typography suitable for an IEEE double-column figure."""
    plt.rcParams.update(
        {
            "font.family": "serif",
            "font.serif": ["Times New Roman", "Times", "DejaVu Serif"],
            "font.size": 8,
            "axes.labelsize": 8,
            "axes.titlesize": 8,
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


def save_figure(fig: plt.Figure, output_dir: Path, stem: str) -> None:
    """Save a 600-DPI PNG figure."""
    output_dir.mkdir(parents=True, exist_ok=True)
    png_path = output_dir / f"{stem}.png"
    fig.savefig(png_path, dpi=600, bbox_inches="tight")
    plt.close(fig)
    print(f"Saved: {png_path}")


def plot_coverage_widths(
    results: list[ProfileResult],
    coverages: dict[int, dict[float, dict[str, CoverageWindow]]],
    output_dir: Path,
) -> None:
    """Plot per-layer W90, W95, and W99 distributions across BFP formats."""
    fig, axes = plt.subplots(1, 3, figsize=(7.16, 2.35), sharey=True)
    rng = np.random.default_rng(0)
    positions = np.arange(len(results))

    for ax, coverage in zip(axes, COVERAGES):
        values = [
            np.asarray(
                [window.span for window in coverages[result.bits][coverage].values()],
                dtype=np.float64,
            )
            for result in results
        ]
        boxes = ax.boxplot(
            values,
            positions=positions,
            widths=0.55,
            patch_artist=True,
            showfliers=False,
            medianprops={"color": "black", "linewidth": 1.0},
            whiskerprops={"color": "0.30", "linewidth": 0.8},
            capprops={"color": "0.30", "linewidth": 0.8},
        )
        for result, box, layer_values, position in zip(results, boxes["boxes"], values, positions):
            color = FORMAT_COLORS[result.bits]
            box.set(facecolor=color, edgecolor="0.25", alpha=0.70, linewidth=0.8)
            jitter = rng.uniform(-0.17, 0.17, size=layer_values.size)
            ax.scatter(
                position + jitter,
                layer_values,
                s=3.5,
                color=color,
                alpha=0.22,
                linewidths=0,
                zorder=1,
            )

        label = f"W{int(round(100 * coverage))}"
        ax.set_title(label)
        ax.set_xticks(positions, [f"BFP{result.bits}" for result in results])
        ax.yaxis.set_major_locator(MaxNLocator(integer=True, nbins=6))
        ax.tick_params(direction="in", top=False, right=False)
        ax.grid(axis="y", color="0.84", linewidth=0.55, linestyle="--", zorder=0)
        ax.spines["top"].set_visible(False)
        ax.spines["right"].set_visible(False)

    axes[0].set_ylabel("Minimum Exponent Span")
    axes[0].set_ylim(bottom=0.0)
    fig.supxlabel("BFP Format", y=0.02)
    fig.tight_layout(rect=(0.0, 0.05, 1.0, 1.0), pad=0.45, w_pad=0.8)
    save_figure(fig, output_dir, "exponent_coverage_width")


def plot_w95_heatmap(
    results: list[ProfileResult],
    coverages: dict[int, dict[float, dict[str, CoverageWindow]]],
    output_dir: Path,
) -> None:
    """Plot W95 for every Transformer layer and Linear projection type."""
    values = {
        result.bits: {
            name: window.span
            for name, window in coverages[result.bits][0.95].items()
        }
        for result in results
    }
    matrices = build_transformer_matrices(results, values)

    vmin = min(int(np.nanmin(matrix)) for matrix in matrices.values())
    vmax = max(int(np.nanmax(matrix)) for matrix in matrices.values())
    boundaries = np.arange(vmin - 0.5, vmax + 1.5, 1.0)
    fig, axes = plt.subplots(2, 3, figsize=(7.16, 4.35), sharex=True, sharey=True)
    flat_axes = axes.ravel()
    cmap = LinearSegmentedColormap.from_list(
        "ieee_sequential_blues",
        SEQUENTIAL_BLUES,
        N=vmax - vmin + 1,
    )
    cmap.set_bad("white")
    norm = BoundaryNorm(boundaries, cmap.N)
    images = []

    for ax, result in zip(flat_axes, results):
        image = ax.imshow(
            matrices[result.bits],
            aspect="auto",
            interpolation="nearest",
            cmap=cmap,
            norm=norm,
        )
        images.append(image)
        ax.set_title(f"BFP{result.bits}", pad=6)
        ax.set_xticks([0, 7, 15, 23, 31])
        ax.set_yticks(np.arange(len(LAYER_TYPES)), LAYER_TYPE_LABELS)
        ax.tick_params(axis="x", direction="out", length=2, labelbottom=True)
        ax.tick_params(axis="y", direction="out", length=2)

    for ax in flat_axes[len(results) :]:
        ax.set_visible(False)

    fig.suptitle("Per-Block W95 Partial-sum Exponent Span", y=0.985)
    fig.supxlabel("Transformer Block Index", y=0.04)
    fig.supylabel("Linear Projection", x=0.015)
    colorbar_axis = fig.add_axes((0.815, 0.19, 0.024, 0.24))
    colorbar = fig.colorbar(
        images[0],
        cax=colorbar_axis,
        boundaries=boundaries,
        ticks=np.arange(vmin, vmax + 1),
    )
    colorbar.set_label("W95 Span (Exponent Steps)")
    fig.subplots_adjust(left=0.18, right=0.97, bottom=0.13, top=0.90, wspace=0.18, hspace=0.34)
    save_figure(fig, output_dir, "per_layer_w95_heatmap")


def plot_full_span_heatmap(
    results: list[ProfileResult],
    output_dir: Path,
) -> None:
    """Plot observed full exponent spans for every Transformer Linear layer."""
    values = {
        result.bits: {
            name: observed_full_span(layer)
            for name, layer in result.layers.items()
        }
        for result in results
    }
    matrices = build_transformer_matrices(results, values)
    vmin = min(int(np.nanmin(matrix)) for matrix in matrices.values())
    vmax = max(int(np.nanmax(matrix)) for matrix in matrices.values())

    fig, axes = plt.subplots(2, 3, figsize=(7.16, 4.35), sharex=True, sharey=True)
    flat_axes = axes.ravel()
    cmap = LinearSegmentedColormap.from_list(
        "ieee_continuous_blues",
        SEQUENTIAL_BLUES,
        N=256,
    )
    cmap.set_bad("white")
    norm = Normalize(vmin=vmin, vmax=vmax)
    images = []

    for ax, result in zip(flat_axes, results):
        image = ax.imshow(
            matrices[result.bits],
            aspect="auto",
            interpolation="nearest",
            cmap=cmap,
            norm=norm,
        )
        images.append(image)
        ax.set_title(f"BFP{result.bits}", pad=6)
        ax.set_xticks([0, 7, 15, 23, 31])
        ax.set_yticks(np.arange(len(LAYER_TYPES)), LAYER_TYPE_LABELS)
        ax.tick_params(axis="x", direction="out", length=2, labelbottom=True)
        ax.tick_params(axis="y", direction="out", length=2)

    for ax in flat_axes[len(results) :]:
        ax.set_visible(False)

    fig.suptitle("Per-Block Full Partial-sum Exponent Span", y=0.985)
    fig.supxlabel("Transformer Block Index", y=0.04)
    fig.supylabel("Linear Projection", x=0.015)
    colorbar_axis = fig.add_axes((0.815, 0.19, 0.024, 0.24))
    colorbar = fig.colorbar(images[0], cax=colorbar_axis)
    colorbar.locator = MaxNLocator(integer=True, nbins=6)
    colorbar.update_ticks()
    colorbar.set_label("Full Span (Exponent Steps)")
    fig.subplots_adjust(left=0.18, right=0.97, bottom=0.13, top=0.90, wspace=0.18, hspace=0.34)
    save_figure(fig, output_dir, "per_layer_full_span_heatmap")


def histogram_limits(results: list[ProfileResult]) -> tuple[int, int, float]:
    """Find common axes for all selected-layer histogram figures."""
    exponent_min: int | None = None
    exponent_max: int | None = None
    frequency_max = 0.0

    for result in results:
        for _, name in SELECTED_LAYERS:
            if name not in result.layers:
                raise KeyError(f"Missing selected layer '{name}' for BFP{result.bits}")
            layer = result.layers[name]
            occupied = np.flatnonzero(layer.counts)
            if occupied.size == 0:
                raise ValueError(f"No nonzero partial sums in {name} for BFP{result.bits}")
            low = int(layer.exponents[occupied[0]])
            high = int(layer.exponents[occupied[-1]])
            exponent_min = low if exponent_min is None else min(exponent_min, low)
            exponent_max = high if exponent_max is None else max(exponent_max, high)
            frequency_max = max(frequency_max, float(layer.frequency_percent.max()))

    if exponent_min is None or exponent_max is None:
        raise RuntimeError("Unable to determine histogram limits")
    return exponent_min - 1, exponent_max + 1, frequency_max * 1.12


def plot_selected_histograms(
    results: list[ProfileResult],
    output_dir: Path,
) -> None:
    """Plot four fixed representative layers for every BFP format."""
    x_min, x_max, y_max = histogram_limits(results)

    for result in results:
        color = FORMAT_COLORS[result.bits]
        fig, axes = plt.subplots(2, 2, figsize=(7.16, 4.85), sharex=True, sharey=True)

        for ax, (label, name) in zip(axes.ravel(), SELECTED_LAYERS):
            layer = result.layers[name]
            frequency = layer.frequency_percent
            occupied = frequency > 0.0
            observed_exponents = layer.exponents[occupied]
            observed_min = int(observed_exponents.min())
            observed_max = int(observed_exponents.max())
            full_span = observed_max - observed_min
            mode = int(layer.exponents[int(np.argmax(layer.counts))])

            ax.axvspan(
                observed_min - 0.5,
                observed_max + 0.5,
                color=color,
                alpha=0.12,
                linewidth=0,
                zorder=0,
            )
            ax.bar(
                layer.exponents[occupied],
                frequency[occupied],
                width=0.82,
                color=color,
                edgecolor="0.22",
                linewidth=0.35,
                zorder=2,
            )
            ax.axvline(mode, color="0.15", linewidth=0.8, linestyle="--", zorder=3)
            ax.text(
                0.025,
                0.92,
                f"Emin={observed_min}  Emax={observed_max}\n"
                f"Full span={full_span}",
                transform=ax.transAxes,
                ha="left",
                va="top",
                fontsize=7,
                bbox={
                    "boxstyle": "square,pad=0.25",
                    "facecolor": "white",
                    "edgecolor": "0.65",
                    "linewidth": 0.5,
                    "alpha": 0.90,
                },
            )
            ax.set_title(label, pad=8)
            ax.set_xlim(x_min, x_max)
            ax.set_ylim(0.0, y_max)
            ax.xaxis.set_major_locator(MaxNLocator(integer=True, nbins=9))
            ax.yaxis.set_major_locator(MaxNLocator(nbins=5))
            ax.yaxis.set_major_formatter(PercentFormatter(xmax=100.0, decimals=0))
            ax.tick_params(
                axis="x",
                direction="in",
                top=False,
                labelbottom=True,
                pad=2,
            )
            ax.tick_params(axis="y", direction="in", right=False)
            ax.grid(axis="y", color="0.84", linewidth=0.55, linestyle="--", zorder=0)
            ax.spines["top"].set_visible(False)
            ax.spines["right"].set_visible(False)

        handles = [
            Patch(facecolor=color, edgecolor="none", alpha=0.12, label="Observed full span"),
            Line2D([0], [0], color="0.15", linestyle="--", linewidth=0.8, label="Mode"),
        ]
        fig.legend(
            handles=handles,
            loc="upper center",
            bbox_to_anchor=(0.5, 0.985),
            ncol=2,
            frameon=False,
            handlelength=1.8,
            columnspacing=1.2,
        )
        fig.supxlabel("Partial-sum Exponent", y=0.025)
        fig.supylabel("Frequency among Nonzero Partials", x=0.018)
        fig.suptitle(f"BFP{result.bits} Group-{result.group_size} Partial-sum Exponents", y=1.025)
        fig.tight_layout(rect=(0.045, 0.05, 1.0, 0.93), pad=0.5, w_pad=0.8, h_pad=1.8)
        save_figure(fig, output_dir, f"bfp{result.bits}_exponent_distribution")


def print_summary(
    results: list[ProfileResult],
    coverages: dict[int, dict[float, dict[str, CoverageWindow]]],
) -> None:
    print("\nPer-layer exponent coverage summary")
    print("Format  Metric  Median  Mean    Min  Max")
    for result in results:
        for coverage in COVERAGES:
            values = np.asarray(
                [window.span for window in coverages[result.bits][coverage].values()],
                dtype=np.float64,
            )
            metric = f"W{int(round(100 * coverage))}"
            print(
                f"BFP{result.bits:<2}   {metric:<4}    {np.median(values):>5.1f}  "
                f"{np.mean(values):>5.2f}  {int(values.min()):>3}  {int(values.max()):>3}"
            )


def main() -> None:
    plot_dir = Path(__file__).resolve().parent
    project_dir = plot_dir.parent
    parser = argparse.ArgumentParser(
        description="Plot per-layer BFP partial-sum exponent profiles."
    )
    parser.add_argument(
        "--profile-dir",
        type=Path,
        default=project_dir / "ob-skip" / "LLaMA2-7B" / "result" / "exponent_profile",
        help="Directory containing bfp{n}-g{G}.json profiler results.",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=plot_dir / "output" / "exponent_profile",
        help="Directory for generated PNG figures.",
    )
    parser.add_argument("--group-size", type=int, default=32)
    parser.add_argument(
        "--formats",
        type=int,
        nargs="+",
        default=list(DEFAULT_FORMATS),
        help="BFP total bit widths in display order.",
    )
    args = parser.parse_args()

    formats = tuple(args.formats)
    if not formats or len(set(formats)) != len(formats):
        raise ValueError("--formats must contain unique BFP widths.")
    if args.group_size <= 0:
        raise ValueError("--group-size must be positive.")

    configure_ieee_style()
    results = load_results(args.profile_dir, formats, args.group_size)
    coverages = compute_coverages(results)
    print_summary(results, coverages)
    plot_coverage_widths(results, coverages, args.output_dir)
    plot_w95_heatmap(results, coverages, args.output_dir)
    plot_full_span_heatmap(results, args.output_dir)
    plot_selected_histograms(results, args.output_dir)


if __name__ == "__main__":
    main()
