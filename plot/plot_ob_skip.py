"""Plot OB-skip PPL changes relative to each original BFP result."""

from __future__ import annotations

import argparse
import json
import re
from collections import defaultdict
from math import floor
from pathlib import Path
from typing import Any

import matplotlib.pyplot as plt
from matplotlib.ticker import MaxNLocator, MultipleLocator, PercentFormatter


OB_SKIP_PATTERN = re.compile(
    r"obskip-bfp(?P<bits>\d+)-g(?P<group>\d+)-t(?P<threshold>\d+)\.json$"
)

# Colorblind-friendly, low-saturation styles for future BFP8--BFP4 curves.
SERIES_STYLES = {
    8: ("#4C78A8", "#2F5597", "o"),
    7: ("#D17C2F", "#A65E1B", "s"),
    6: ("#59A14F", "#3B7D35", "^"),
    5: ("#E15759", "#A63D40", "D"),
    4: ("#8064A2", "#5B3E75", "P"),
}


def load_result(path: Path) -> dict[str, Any]:
    """Load one result JSON file."""
    with path.open("r", encoding="utf-8") as file:
        return json.load(file)


def load_ppl(path: Path) -> float:
    """Load the ``perplexity`` field from one result JSON file."""
    data = load_result(path)

    if "perplexity" not in data:
        raise KeyError(f"Missing 'perplexity' in {path}")

    return float(data["perplexity"])


def load_ob_skip_series(
    ob_skip_dir: Path,
    baseline_dir: Path,
    group_size: int,
    threshold_min: int,
    threshold_max: int,
) -> dict[int, list[tuple[int, float, float]]]:
    """Group OB-skip results and load delta PPL plus non-skip rate."""
    series: dict[int, list[tuple[int, float, float]]] = defaultdict(list)

    for path in ob_skip_dir.glob("obskip-bfp*-g*-t*.json"):
        match = OB_SKIP_PATTERN.fullmatch(path.name)
        if match is None:
            continue

        bits = int(match.group("bits"))
        file_group_size = int(match.group("group"))
        threshold = int(match.group("threshold"))

        if file_group_size != group_size:
            continue
        if not threshold_min <= threshold <= threshold_max:
            continue

        baseline_path = baseline_dir / f"bfp{bits}-g{group_size}.json"
        if not baseline_path.exists():
            raise FileNotFoundError(
                f"Missing original BFP result for {path.name}: {baseline_path}"
            )

        ob_skip_result = load_result(path)
        if "perplexity" not in ob_skip_result:
            raise KeyError(f"Missing 'perplexity' in {path}")

        stats = ob_skip_result.get("ob_skip_stats", {})
        if "normal_add_rate" in stats:
            non_skip_rate = float(stats["normal_add_rate"])
        elif "ob_skip_rate" in stats:
            non_skip_rate = 1.0 - float(stats["ob_skip_rate"])
        else:
            raise KeyError(f"Missing non-skip rate in {path}")

        # Negative delta means OB-skip achieves lower (better) PPL than BFP.
        delta_ppl = float(ob_skip_result["perplexity"]) - load_ppl(baseline_path)
        series[bits].append((threshold, delta_ppl, 100.0 * non_skip_rate))

    if not series:
        raise FileNotFoundError(f"No matching OB-skip results found in {ob_skip_dir}")

    for values in series.values():
        values.sort(key=lambda item: item[0])

    return dict(series)


def configure_ieee_style() -> None:
    """Configure compact typography for an IEEE single-column figure."""
    plt.rcParams.update(
        {
            "font.family": "serif",
            "font.serif": ["Times New Roman", "Times", "DejaVu Serif"],
            "font.size": 8,
            "axes.labelsize": 8,
            "xtick.labelsize": 7,
            "ytick.labelsize": 7,
            "axes.linewidth": 0.8,
            "xtick.major.width": 0.8,
            "ytick.major.width": 0.8,
            "xtick.major.size": 3,
            "ytick.major.size": 3,
        }
    )


def plot_ob_skip(
    ob_skip_dir: Path,
    baseline_dir: Path,
    output_dir: Path,
    group_size: int,
    threshold_min: int,
    threshold_max: int,
) -> None:
    series = load_ob_skip_series(
        ob_skip_dir,
        baseline_dir,
        group_size,
        threshold_min,
        threshold_max,
    )
    configure_ieee_style()

    fig, ax = plt.subplots(figsize=(5.6, 3.0))
    ax_rate = ax.twinx()
    all_delta_ppl: list[float] = []
    all_non_skip_rates: list[float] = []
    legend_handles = []
    legend_labels: list[str] = []

    for bits in sorted(series, reverse=True):
        values = series[bits]
        thresholds = [threshold for threshold, _, _ in values]
        delta_ppl = [delta for _, delta, _ in values]
        non_skip_rates = [rate for _, _, rate in values]
        all_delta_ppl.extend(delta_ppl)
        all_non_skip_rates.extend(non_skip_rates)

        color, edge_color, marker = SERIES_STYLES.get(
            bits,
            ("0.35", "0.15", "o"),
        )
        delta_line, = ax.plot(
            thresholds,
            delta_ppl,
            color=color,
            linewidth=1.2,
            linestyle="-",
            marker=marker,
            markersize=4.5,
            markerfacecolor=color,
            markeredgecolor=edge_color,
            markeredgewidth=1.0,
            zorder=3,
        )
        rate_line, = ax_rate.plot(
            thresholds,
            non_skip_rates,
            color=color,
            linewidth=1.1,
            linestyle="--",
            marker=marker,
            markersize=4.5,
            markerfacecolor="white",
            markeredgecolor=edge_color,
            markeredgewidth=1.0,
            zorder=2,
        )
        legend_handles.extend((delta_line, rate_line))
        legend_labels.extend((rf"BFP{bits} $\Delta$PPL", f"BFP{bits} Non-skip"))

    ax.set_xlabel("Threshold")
    ax.set_ylabel(r"$\Delta$PPL")
    ax_rate.set_ylabel("Non-skip Rate")
    ax.set_xticks(range(threshold_min, threshold_max + 1))
    ax.set_xlim(threshold_min - 0.25, threshold_max + 0.25)
    ax.yaxis.set_major_locator(MaxNLocator(nbins=5))
    ax.tick_params(direction="in", top=False, right=False)
    ax_rate.tick_params(direction="in", top=False, left=False)
    ax.spines["top"].set_visible(False)
    ax.spines["right"].set_visible(False)
    ax_rate.spines["top"].set_visible(False)

    y_min = min(0.0, min(all_delta_ppl))
    y_max = max(0.0, max(all_delta_ppl))
    y_span = max(0.1, y_max - y_min)
    y_margin = 0.10 * y_span
    ax.set_ylim(y_min - y_margin, y_max + y_margin)

    rate_lower = max(0.0, 5.0 * floor((min(all_non_skip_rates) - 2.0) / 5.0))
    # Leave headroom above 100% so near-boundary markers are not clipped.
    ax_rate.set_ylim(rate_lower, 100.5)
    ax_rate.yaxis.set_major_locator(MultipleLocator(2.0))
    ax_rate.yaxis.set_major_formatter(PercentFormatter(xmax=100.0, decimals=0))

    visible_ticks = [
        tick for tick in ax.get_yticks() if ax.get_ylim()[0] <= tick <= ax.get_ylim()[1]
    ]
    for y_tick in visible_ticks[1:]:
        if abs(y_tick) < 1e-12:
            continue
        ax.axhline(
            y_tick,
            color="0.82",
            linewidth=0.55,
            linestyle="--",
            zorder=0,
        )

    legend = fig.legend(
        legend_handles,
        legend_labels,
        loc="upper center",
        bbox_to_anchor=(0.5, 0.99),
        ncol=5,
        frameon=True,
        fancybox=False,
        framealpha=0.95,
        facecolor="white",
        edgecolor="0.60",
        fontsize=7,
        handlelength=2.0,
        handletextpad=0.6,
        columnspacing=0.85,
        borderpad=0.55,
    )
    legend.get_frame().set_linewidth(0.6)

    output_dir.mkdir(parents=True, exist_ok=True)
    fig.tight_layout(rect=(0.0, 0.0, 1.0, 0.84), pad=0.35)
    fig.savefig(
        output_dir / "ob_skip_dual_axis_plot.png",
        dpi=600,
        bbox_inches="tight",
    )
    plt.close(fig)


def main() -> None:
    plot_dir = Path(__file__).resolve().parent
    project_dir = plot_dir.parent
    parser = argparse.ArgumentParser(
        description="Plot OB-skip PPL changes relative to original BFP results."
    )
    parser.add_argument(
        "--ob-skip-dir",
        type=Path,
        default=project_dir / "ob-skip" / "LLaMA2-7B" / "result",
        help="Directory containing LLaMA 2-7B OB-skip result JSON files.",
    )
    parser.add_argument(
        "--baseline-dir",
        type=Path,
        default=project_dir / "model" / "LLaMA2-7B" / "result",
        help="Directory containing the original BFP result JSON files.",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=plot_dir / "output",
        help="Directory for the generated PNG file.",
    )
    parser.add_argument("--group-size", type=int, default=32)
    parser.add_argument("--threshold-min", type=int, default=8)
    parser.add_argument("--threshold-max", type=int, default=12)
    args = parser.parse_args()

    plot_ob_skip(
        args.ob_skip_dir,
        args.baseline_dir,
        args.output_dir,
        args.group_size,
        args.threshold_min,
        args.threshold_max,
    )


if __name__ == "__main__":
    main()
