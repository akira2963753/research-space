from __future__ import annotations

import re
from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np
from matplotlib.ticker import FormatStrFormatter, MultipleLocator


PLOT_DIR = Path(__file__).resolve().parent
RTL_ROOT = PLOT_DIR.parents[1] / "rtl"
FIGURE_STEM = PLOT_DIR / "figures" / "pe_area_energy_comparison"

BASELINE_REPORT = RTL_ROOT / "01_Baseline-BFP-PE" / "BFP4" / "02_SYN" / "Report"
BUCKET_REPORT = RTL_ROOT / "02_Bucket-Getter-PE" / "Report"
OURS_AREA_REPORT = RTL_ROOT / "03_DEW-PE" / "02_SYN" / "Sweep_Report" / "W13" / "area.rpt"
OURS_POWER_REPORT = RTL_ROOT / "03_DEW-PE" / "02_SYN" / "Report" / "power.rpt"

DESIGNS = (
    ("Baseline", BASELINE_REPORT / "area.rpt", BASELINE_REPORT / "power.rpt"),
    ("Bucket", BUCKET_REPORT / "area.rpt", BUCKET_REPORT / "power.rpt"),
    ("Ours", OURS_AREA_REPORT, OURS_POWER_REPORT),
)

AREA_RE = re.compile(r"^Total cell area:\s+([0-9.]+)", re.MULTILINE)
POWER_RE = re.compile(
    r"^Total\s+[0-9.]+ mW\s+[0-9.]+ mW\s+[0-9.eE+-]+ pW\s+([0-9.]+) mW",
    re.MULTILINE,
)
# Light fills from plot/05_pe-power-area; dark solids look too heavy as full bars.
AREA_COLOR = "#BCDCE1"
ENERGY_COLOR = "#F4DFB6"
EDGE_COLOR = "#000000"
TEXT_COLOR = "#232323"
GRID_COLOR = "#DDE3E9"


def configure_ieee_style() -> None:
    plt.rcParams.update(
        {
            "font.family": "serif",
            "font.serif": [
                "EB Garamond",
                "Garamond",
                "Times New Roman",
                "DejaVu Serif",
            ],
            "font.weight": "bold",
            "font.size": 8,
            "axes.labelsize": 8,
            "axes.labelweight": "bold",
            "axes.titleweight": "bold",
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


def parse_area(area_path: Path) -> float:
    area_text = area_path.read_text(encoding="utf-8", errors="ignore")
    area_match = AREA_RE.search(area_text)
    if area_match is None:
        raise ValueError(f"Missing total cell area in {area_path}")
    return float(area_match.group(1))


def parse_power(power_path: Path) -> float:
    power_text = power_path.read_text(encoding="utf-8", errors="ignore")
    power_matches = POWER_RE.findall(power_text)
    if not power_matches:
        raise ValueError(f"Missing total power in {power_path}")
    return float(power_matches[-1])


def save_figure(fig: plt.Figure, stem: Path) -> None:
    stem.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(
        stem.with_suffix(".png"),
        dpi=600,
        bbox_inches="tight",
        pad_inches=0.02,
    )
    fig.savefig(
        stem.with_suffix(".pdf"),
        bbox_inches="tight",
        pad_inches=0.02,
    )
    plt.close(fig)


def plot_comparison() -> None:
    labels = [name for name, _, _ in DESIGNS]
    areas = []
    powers = []
    for name, area_path, power_path in DESIGNS:
        area = parse_area(area_path)
        power = parse_power(power_path)
        areas.append(area)
        powers.append(power)
        print(f"{name}: area={area:.4f} ({area_path.name})  total_power={power:.4f} mW")
        print(f"  area <- {area_path}")
        print(f"  power <- {power_path}")

    areas = np.asarray(areas, dtype=np.float64)
    powers = np.asarray(powers, dtype=np.float64)
    area_norm = areas / areas[0]
    energy_norm = powers / powers[0]

    configure_ieee_style()
    fig, ax = plt.subplots(figsize=(3.55, 2.15))
    x = np.arange(len(labels), dtype=np.float64)
    bar_width = 0.32

    area_bars = ax.bar(
        x - bar_width / 2.0,
        area_norm,
        width=bar_width,
        color=AREA_COLOR,
        edgecolor=EDGE_COLOR,
        linewidth=0.95,
        label="Area",
        zorder=3,
    )
    energy_bars = ax.bar(
        x + bar_width / 2.0,
        energy_norm,
        width=bar_width,
        color=ENERGY_COLOR,
        edgecolor=EDGE_COLOR,
        linewidth=0.95,
        label="Energy",
        zorder=3,
    )

    ax.bar_label(
        area_bars,
        labels=[f"{value:.2f}" for value in area_norm],
        padding=1.5,
        fontsize=6.5,
        color=TEXT_COLOR,
        zorder=4,
    )
    ax.bar_label(
        energy_bars,
        labels=[f"{value:.2f}" for value in energy_norm],
        padding=1.5,
        fontsize=6.5,
        color=TEXT_COLOR,
        zorder=4,
    )

    ax.set_xticks(x)
    ax.set_xticklabels(labels, color=TEXT_COLOR)
    ax.set_ylabel("Normalized", color=TEXT_COLOR)
    ax.set_ylim(0.0, max(area_norm.max(), energy_norm.max()) * 1.18)
    ax.yaxis.set_major_locator(MultipleLocator(0.2))
    ax.yaxis.set_major_formatter(FormatStrFormatter("%.1f"))
    ax.set_axisbelow(True)
    ax.grid(
        axis="y",
        color=GRID_COLOR,
        linewidth=0.5,
        linestyle="-",
        zorder=0,
    )
    ax.spines["top"].set_visible(False)
    ax.spines["right"].set_visible(False)
    ax.spines["left"].set_color(TEXT_COLOR)
    ax.spines["bottom"].set_color(TEXT_COLOR)
    ax.tick_params(axis="x", length=0, pad=3.0, colors=TEXT_COLOR)
    ax.tick_params(axis="y", direction="out", length=2.5, width=0.7, pad=2.0, colors=TEXT_COLOR)
    ax.legend(
        loc="upper right",
        frameon=False,
        handlelength=1.35,
        handletextpad=0.45,
        borderaxespad=0.15,
        labelcolor=TEXT_COLOR,
    )

    fig.tight_layout(pad=0.35)
    save_figure(fig, FIGURE_STEM)
    print("Normalization: Baseline = 1.0")
    print("Ours area is DEW_ACC_W=13; energy is DC total power from the W24 report.")
    print(f"Saved: {FIGURE_STEM.with_suffix('.png')}")
    print(f"Saved: {FIGURE_STEM.with_suffix('.pdf')}")


if __name__ == "__main__":
    plot_comparison()
