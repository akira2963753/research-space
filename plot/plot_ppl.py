"""Plot quantization-induced PPL increases in an IEEE paper-friendly style."""

from __future__ import annotations

import argparse
import json
from dataclasses import dataclass
from pathlib import Path

import matplotlib.pyplot as plt
from matplotlib.ticker import MaxNLocator


RESULT_FILES = [
    ("Baseline\n(FP16)", "baseline.json"),
    ("BFP8", "bfp8-g32.json"),
    ("BFP7", "bfp7-g32.json"),
    ("BFP6", "bfp6-g32.json"),
    ("BFP5", "bfp5-g32.json"),
    ("BFP4", "bfp4-g32.json"),
]


@dataclass(frozen=True)
class ModelSpec:
    """Input directory and visual style for one model curve."""

    label: str
    result_dir: Path
    color: str
    edge_color: str
    marker: str
    linestyle: str


MODEL_SPECS = [
    ModelSpec(
        label="LLaMA 2-7B",
        result_dir=Path("model") / "LLaMA2-7B" / "result",
        color="#4C78A8",
        edge_color="#2F5597",
        marker="o",
        linestyle="-",
    ),
    ModelSpec(
        label="LLaMA 2-13B",
        result_dir=Path("model") / "LLaMA2-13B" / "result",
        color="#D17C2F",
        edge_color="#A65E1B",
        marker="s",
        linestyle="-",
    ),
    ModelSpec(
        label="LLaMA 3.1-8B",
        result_dir=Path("model") / "LLaMA3.1-8B" / "result",
        color="#59A14F",
        edge_color="#3B7D35",
        marker="^",
        linestyle="-",
    ),
    ModelSpec(
        label="OPT-6.7B",
        result_dir=Path("model") / "OPT-6.7B" / "result",
        color="#E15759",
        edge_color="#A63D40",
        marker="D",
        linestyle="-",
    ),
]


def load_perplexities(result_dir: Path) -> tuple[list[str], list[float]]:
    """Load the ``perplexity`` field from each experiment JSON file."""
    labels: list[str] = []
    perplexities: list[float] = []

    for label, filename in RESULT_FILES:
        path = result_dir / filename
        with path.open("r", encoding="utf-8") as file:
            data = json.load(file)

        if "perplexity" not in data:
            raise KeyError(f"Missing 'perplexity' in {path}")

        labels.append(label)
        perplexities.append(float(data["perplexity"]))

    return labels, perplexities


def configure_ieee_style() -> None:
    """Configure compact fonts and vector-font embedding for IEEE figures."""
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


def plot_delta_ppl(project_dir: Path, output_dir: Path) -> None:
    # FP16 is the reference, so only quantized formats are shown on the x-axis.
    labels = [label for label, _ in RESULT_FILES[1:]]
    model_values: list[tuple[ModelSpec, list[float]]] = []

    for spec in MODEL_SPECS:
        _, perplexities = load_perplexities(project_dir / spec.result_dir)
        baseline_ppl = perplexities[0]
        delta_ppl = [ppl - baseline_ppl for ppl in perplexities[1:]]
        model_values.append((spec, delta_ppl))

    all_delta_ppl = [value for _, values in model_values for value in values]
    configure_ieee_style()

    # 3.5 in matches the approximate width of one IEEE journal column.
    fig, ax = plt.subplots(figsize=(3.5, 2.35))
    x = range(len(labels))

    for spec, delta_ppl in model_values:
        ax.plot(
            x,
            delta_ppl,
            color=spec.color,
            linewidth=1.2,
            linestyle=spec.linestyle,
            marker=spec.marker,
            markersize=3.6,
            markerfacecolor=spec.color,
            markeredgecolor=spec.edge_color,
            markeredgewidth=0.8,
            label=spec.label,
            zorder=3,
        )

    ax.set_xlabel("Data Format")
    ax.set_ylabel(r"$\Delta$PPL")
    ax.set_xticks(list(x), labels)
    ax.yaxis.set_major_locator(MaxNLocator(nbins=5))
    ax.tick_params(direction="in", top=False, right=False)
    ax.spines["top"].set_visible(False)
    ax.spines["right"].set_visible(False)
    legend = ax.legend(
        loc="upper left",
        frameon=True,
        fancybox=False,
        framealpha=0.95,
        facecolor="white",
        edgecolor="0.60",
        fontsize=7,
        handlelength=2.0,
        handletextpad=0.6,
        borderaxespad=0.6,
        borderpad=0.55,
    )
    legend.get_frame().set_linewidth(0.6)

    min_delta_ppl = min(all_delta_ppl)
    max_delta_ppl = max(all_delta_ppl)
    upper_margin = max(0.05, 0.10 * max_delta_ppl)
    lower_limit = 0.0
    if min_delta_ppl < 0.0:
        lower_limit = min_delta_ppl - max(0.01, 0.10 * abs(min_delta_ppl))
    ax.set_ylim(lower_limit, max_delta_ppl + upper_margin)

    # Draw horizontal guides except at the lowest visible tick (e.g., 4.75).
    y_min, y_max = ax.get_ylim()
    visible_y_ticks = [tick for tick in ax.get_yticks() if y_min <= tick <= y_max]
    for y_tick in visible_y_ticks[1:]:
        if abs(y_tick) < 1e-12:
            continue
        ax.axhline(
            y_tick,
            color="0.82",
            linewidth=0.55,
            linestyle="--",
            zorder=0,
        )

    output_dir.mkdir(parents=True, exist_ok=True)
    fig.tight_layout(pad=0.35)
    fig.savefig(output_dir / "ppl_delta_plot.png", dpi=600, bbox_inches="tight")
    plt.close(fig)


def main() -> None:
    plot_dir = Path(__file__).resolve().parent
    project_dir = plot_dir.parent
    parser = argparse.ArgumentParser(
        description="Plot PPL increases from BFP quantization as an IEEE-style chart."
    )
    parser.add_argument(
        "--project-dir",
        type=Path,
        default=project_dir,
        help="Project directory containing the model result folders.",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=plot_dir / "output",
        help="Directory for the generated PNG file.",
    )
    args = parser.parse_args()
    plot_delta_ppl(args.project_dir, args.output_dir)


if __name__ == "__main__":
    main()
