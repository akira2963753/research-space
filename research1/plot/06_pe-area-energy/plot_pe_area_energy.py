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
BUCKET_REPORT = RTL_ROOT / "02_Bucket-Getter-PE" / "02_SYN" / "Report"
OURS_AREA_DIR = RTL_ROOT / "03_DEW-PE" / "02_SYN" / "Sweep_Report" / "W13"
OURS_POWER_REPORT = RTL_ROOT / "03_DEW-PE" / "02_SYN" / "Report" / "power.rpt"

# share_fp_acc: count half of u_fp_acc to model two PEs sharing one FP-Acc.
DESIGNS = (
    ("Baseline", BASELINE_REPORT / "area.rpt", BASELINE_REPORT / "area_h.rpt", BASELINE_REPORT / "power.rpt", False),
    ("Bucket", BUCKET_REPORT / "area.rpt", BUCKET_REPORT / "area_h.rpt", BUCKET_REPORT / "power.rpt", True),
    ("Ours", OURS_AREA_DIR / "area.rpt", OURS_AREA_DIR / "area_h.rpt", OURS_POWER_REPORT, True),
)

AREA_RE = re.compile(r"^Total cell area:\s+([0-9.]+)", re.MULTILINE)
FP_ACC_AREA_RE = re.compile(r"^u_fp_acc\s+([0-9.]+)", re.MULTILINE)
POWER_RE = re.compile(
    r"^Total\s+[0-9.eE+-]+ mW\s+[0-9.eE+-]+ mW\s+[0-9.eE+-]+ pW\s+([0-9.eE+-]+) mW",
    re.MULTILINE,
)
# Desaturated teal / sand; keep the 05 family without the heavy chroma.
AREA_COLOR = "#7D9EA5"
ENERGY_COLOR = "#C9B17A"
EDGE_COLOR = "#1A1A1A"
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


def parse_fp_acc_area(area_h_path: Path) -> float:
    area_h_text = area_h_path.read_text(encoding="utf-8", errors="ignore")
    fp_match = FP_ACC_AREA_RE.search(area_h_text)
    if fp_match is None:
        raise ValueError(f"Missing u_fp_acc area in {area_h_path}")
    return float(fp_match.group(1))


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
    labels = [name for name, _, _, _, _ in DESIGNS]
    areas = []
    powers = []
    for name, area_path, area_h_path, power_path, share_fp_acc in DESIGNS:
        area = parse_area(area_path)
        fp_acc_area = parse_fp_acc_area(area_h_path)
        if share_fp_acc:
            area = area - 0.5 * fp_acc_area
        power = parse_power(power_path)
        areas.append(area)
        powers.append(power)
        share_note = "half FP-Acc" if share_fp_acc else "full FP-Acc"
        print(
            f"{name}: area={area:.4f} ({share_note}, fp_acc={fp_acc_area:.4f})  "
            f"total_power={power:.4f} mW"
        )

    areas = np.asarray(areas, dtype=np.float64)
    powers = np.asarray(powers, dtype=np.float64)
    area_norm = areas / areas[0]
    energy_norm = powers / powers[0]

    configure_ieee_style()
    fig, ax = plt.subplots(figsize=(3.55, 2.15))
    bar_width = 0.14
    group_gap = 0.58
    pair_gap = 0.03
    x = np.arange(len(labels), dtype=np.float64) * group_gap

    area_bars = ax.bar(
        x - bar_width / 2.0 - pair_gap / 2.0,
        area_norm,
        width=bar_width,
        color=AREA_COLOR,
        edgecolor=EDGE_COLOR,
        linewidth=0.70,
        label="Area",
        zorder=3,
    )
    energy_bars = ax.bar(
        x + bar_width / 2.0 + pair_gap / 2.0,
        energy_norm,
        width=bar_width,
        color=ENERGY_COLOR,
        edgecolor=EDGE_COLOR,
        linewidth=0.70,
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
    ax.set_xlim(x[0] - bar_width - pair_gap - 0.10, x[-1] + bar_width + pair_gap + 0.10)
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
    print("Bucket/Ours area counts half of u_fp_acc to model two-PE sharing.")
    print(f"Saved: {FIGURE_STEM.with_suffix('.png')}")
    print(f"Saved: {FIGURE_STEM.with_suffix('.pdf')}")


if __name__ == "__main__":
    plot_comparison()
