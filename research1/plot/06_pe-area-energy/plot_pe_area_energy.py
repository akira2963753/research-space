from __future__ import annotations

import re
import shutil
from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np
from matplotlib.patches import Patch
from matplotlib.ticker import FormatStrFormatter, MultipleLocator


PLOT_DIR = Path(__file__).resolve().parent
RTL_ROOT = PLOT_DIR.parents[1] / "rtl"
RESEARCH_ROOT = PLOT_DIR.parents[2]
FIGURE_STEM = PLOT_DIR / "figures" / "pe_area_energy_comparison"
PAPER_FIGURE_DIRS = (
    RESEARCH_ROOT / "ipas" / "figures",
    RESEARCH_ROOT / "thesis" / "figures",
)

BASELINE_REPORT = RTL_ROOT / "01_Baseline-BFP-PE" / "BFP4" / "02_SYN" / "Report"
BUCKET_REPORT = RTL_ROOT / "02_Bucket-Getter-PE" / "02_SYN" / "Report"
# Area comes from the W13 sweep; power stays on the 02_SYN Report netlist.
OURS_AREA_H = RTL_ROOT / "03_DEW-PE" / "02_SYN" / "Sweep_Report" / "W13" / "area_h.rpt"
OURS_POWER_H = RTL_ROOT / "03_DEW-PE" / "02_SYN" / "Report" / "power_h.rpt"

# share_fp_acc: count half of u_fp_acc area to model two PEs sharing one FP-Acc.
# Power is left unscaled: 02_SYN Report is vectorless power of the synthesized PE.
DESIGNS = (
    ("Baseline", BASELINE_REPORT / "area_h.rpt", BASELINE_REPORT / "power_h.rpt", False),
    ("Bucket", BUCKET_REPORT / "area_h.rpt", BUCKET_REPORT / "power_h.rpt", True),
    ("Ours", OURS_AREA_H, OURS_POWER_H, True),
)

# Bottom-to-top stack: Other as a base so the top edge is a solid FP-Acc cap.
# Outlier dispatcher is counted inside INT-MAC.
COMPONENTS = (
    "Other",
    "INT-MAC",
    "BG-Acc",
    "DEW-Acc",
    "FP-Acc",
)
LEGEND_ORDER = (
    "INT-MAC",
    "BG-Acc",
    "DEW-Acc",
    "FP-Acc",
    "Other",
)

AREA_H_RE = re.compile(
    r"^(\S+)\s+([0-9.]+)\s+[0-9.]+\s+[0-9.]+\s+[0-9.]+\s+[0-9.]+\s+\S+",
)
POWER_NUM = r"[0-9.eE+-]+"
POWER_ROW_RE = re.compile(
    rf"^(\S+)(?:\s+\(\S+\))?\s+({POWER_NUM})\s+({POWER_NUM})\s+({POWER_NUM})\s+({POWER_NUM})\s+({POWER_NUM})\s*$"
)
POWER_NAME_RE = re.compile(r"^(\S+)\s+\(\S+\)\s*$")
POWER_CONT_RE = re.compile(
    rf"^({POWER_NUM})\s+({POWER_NUM})\s+({POWER_NUM})\s+({POWER_NUM})\s+({POWER_NUM})\s*$"
)

COMPONENT_COLORS = {
    "INT-MAC": "#E6D5B8",
    "BG-Acc":  "#C8B882",
    "DEW-Acc": "#B0C4B8",
    "FP-Acc":  "#7AADA8",
    "Other":   "#C8BFB0",
}
EDGE_COLOR = "#3D3D3D"
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
            "legend.fontsize": 6.5,
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


def _float_token(token: str) -> float:
    return float(token)


def parse_area_instances(area_h_path: Path) -> dict[str, float]:
    text = area_h_path.read_text(encoding="utf-8", errors="ignore")
    instances: dict[str, float] = {}
    in_table = False
    for raw_line in text.splitlines():
        line = raw_line.rstrip()
        if line.startswith("Hierarchical cell"):
            in_table = True
            continue
        if not in_table or not line or line.startswith("---") or line.startswith("Total"):
            continue
        match = AREA_H_RE.match(line)
        if match is None:
            continue
        instances[match.group(1)] = _float_token(match.group(2))
    if not instances:
        raise ValueError(f"Missing hierarchical area rows in {area_h_path}")
    return instances


def parse_power_instances(power_h_path: Path) -> dict[str, float]:
    text = power_h_path.read_text(encoding="utf-8", errors="ignore")
    instances: dict[str, float] = {}
    pending_name: str | None = None
    in_table = False
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if line.startswith("Hierarchy"):
            in_table = True
            continue
        if not in_table or not line or line.startswith("---"):
            continue
        if pending_name is not None:
            cont = POWER_CONT_RE.match(line)
            if cont is None:
                raise ValueError(f"Missing power numbers after {pending_name} in {power_h_path}")
            instances[pending_name] = _float_token(cont.group(4))
            pending_name = None
            continue
        row = POWER_ROW_RE.match(line)
        if row is not None:
            instances[row.group(1)] = _float_token(row.group(5))
            continue
        name_only = POWER_NAME_RE.match(line)
        if name_only is not None:
            pending_name = name_only.group(1)
    if pending_name is not None:
        raise ValueError(f"Unfinished power row for {pending_name} in {power_h_path}")
    if not instances:
        raise ValueError(f"Missing hierarchical power rows in {power_h_path}")
    return instances


def _first_value(instances: dict[str, float], keys: tuple[str, ...], default: float = 0.0) -> float:
    for key in keys:
        if key in instances:
            return instances[key]
    return default


def _top_total(instances: dict[str, float]) -> float:
    for name, value in instances.items():
        if not name.startswith("u_"):
            return value
    raise ValueError(f"Missing top-level total in {sorted(instances)}")


def split_components(instances: dict[str, float]) -> dict[str, float]:
    total = _top_total(instances)
    fp_acc = _first_value(instances, ("u_fp_acc",))
    bg_acc = _first_value(instances, ("u_bg_acc",))
    dew_acc = _first_value(instances, ("u_dew_acc",))
    dispatcher = _first_value(
        instances,
        ("u_outlier_dispatcher", "u_int_mac/u_outlier_dispatcher"),
    )
    int_mac = _first_value(instances, ("u_int_mac",))
    # Fold dispatcher into INT-MAC. W13 already nests it; 02_SYN Report lists it as a sibling.
    if "u_outlier_dispatcher" in instances:
        int_mac += dispatcher
    accounted = int_mac + bg_acc + dew_acc + fp_acc
    other = total - accounted
    if other < -1.0:
        raise ValueError(f"Component sum exceeds total: {accounted:.4f} > {total:.4f}")
    return {
        "INT-MAC": int_mac,
        "BG-Acc": bg_acc,
        "DEW-Acc": dew_acc,
        "FP-Acc": max(fp_acc, 0.0),
        "Other": max(other, 0.0),
        "_total": total,
    }


def load_design(name: str, area_h: Path, power_h: Path, share_fp_acc: bool) -> dict[str, float | str | bool]:
    area = split_components(parse_area_instances(area_h))
    power = split_components(parse_power_instances(power_h))
    if share_fp_acc:
        area["FP-Acc"] *= 0.5
        area["_total"] -= area["FP-Acc"]
    return {
        "name": name,
        "share_fp_acc": share_fp_acc,
        "area": area,
        "power": power,
    }


def save_figure(fig: plt.Figure, stem: Path) -> None:
    stem.parent.mkdir(parents=True, exist_ok=True)
    png_path = stem.with_suffix(".png")
    pdf_path = stem.with_suffix(".pdf")
    fig.savefig(png_path, dpi=600, bbox_inches="tight", pad_inches=0.02)
    fig.savefig(pdf_path, bbox_inches="tight", pad_inches=0.02)
    plt.close(fig)
    for paper_dir in PAPER_FIGURE_DIRS:
        if not paper_dir.is_dir():
            continue
        shutil.copy2(png_path, paper_dir / png_path.name)
        shutil.copy2(pdf_path, paper_dir / pdf_path.name)


def plot_comparison() -> None:
    records = [load_design(*spec) for spec in DESIGNS]
    labels = [str(record["name"]) for record in records]
    area_stacks = np.array(
        [[float(record["area"][component]) for record in records] for component in COMPONENTS],
        dtype=np.float64,
    )
    energy_stacks = np.array(
        [[float(record["power"][component]) for record in records] for component in COMPONENTS],
        dtype=np.float64,
    )
    area_totals = area_stacks.sum(axis=0)
    energy_totals = energy_stacks.sum(axis=0)
    area_norm = area_stacks / area_totals[0]
    energy_norm = energy_stacks / energy_totals[0]
    area_total_norm = area_norm.sum(axis=0)
    energy_total_norm = energy_norm.sum(axis=0)

    for record, area_total, energy_total in zip(records, area_totals, energy_totals):
        share_note = "half FP-Acc area" if record["share_fp_acc"] else "full FP-Acc area"
        print(f"{record['name']}: area={area_total:.4f} ({share_note})  total_power={energy_total:.4f} mW")
        for component in COMPONENTS:
            area_value = float(record["area"][component])
            power_value = float(record["power"][component])
            if area_value == 0.0 and power_value == 0.0:
                continue
            print(f"  {component:12s}  area={area_value:10.4f}  power={power_value:.4f} mW")

    configure_ieee_style()
    fig, axes = plt.subplots(1, 2, figsize=(3.55, 2.20), sharey=True)
    x = np.arange(len(labels), dtype=np.float64)
    bar_width = 0.58
    y_max = max(area_total_norm.max(), energy_total_norm.max()) * 1.14

    def draw_panel(ax, stacks: np.ndarray, totals: np.ndarray, title: str, show_ylabel: bool) -> None:
        bottom = np.zeros(len(labels), dtype=np.float64)
        top_bars = None
        for index, component in enumerate(COMPONENTS):
            values = stacks[index]
            if np.all(values <= 1.0e-12):
                continue
            bars = ax.bar(
                x,
                values,
                width=bar_width,
                bottom=bottom,
                color=COMPONENT_COLORS[component],
                edgecolor=EDGE_COLOR,
                linewidth=1.10,
                zorder=3,
            )
            for patch, value in zip(bars.patches, values):
                if value <= 1.0e-12:
                    patch.set_visible(False)
            top_bars = bars
            bottom += values
        ax.bar_label(
            top_bars,
            labels=[f"{value:.2f}" for value in totals],
            padding=2.0,
            fontsize=6.5,
            color=TEXT_COLOR,
            zorder=4,
        )
        ax.set_title(title, fontsize=8, pad=4, color=TEXT_COLOR, fontweight="bold")
        ax.set_xticks(x)
        ax.set_xticklabels(labels, color=TEXT_COLOR)
        ax.set_xlim(-0.55, len(labels) - 0.45)
        ax.set_ylim(0.0, y_max)
        ax.yaxis.set_major_locator(MultipleLocator(0.2))
        ax.yaxis.set_major_formatter(FormatStrFormatter("%.1f"))
        ax.set_axisbelow(True)
        ax.grid(axis="y", color=GRID_COLOR, linewidth=0.5, linestyle="-", zorder=0)
        ax.spines["top"].set_visible(False)
        ax.spines["right"].set_visible(False)
        ax.spines["left"].set_color(TEXT_COLOR)
        ax.spines["bottom"].set_color(TEXT_COLOR)
        ax.tick_params(axis="x", length=0, pad=3.0, colors=TEXT_COLOR)
        ax.tick_params(axis="y", direction="out", length=2.5, width=0.7, pad=1.5, colors=TEXT_COLOR)
        if show_ylabel:
            ax.set_ylabel("Normalized", color=TEXT_COLOR)
        else:
            ax.tick_params(axis="y", labelleft=False)

    draw_panel(axes[0], area_norm, area_total_norm, "Area", True)
    draw_panel(axes[1], energy_norm, energy_total_norm, "Energy", False)

    used = [component for component in LEGEND_ORDER if component in COMPONENTS]
    legend_handles = [
        Patch(
            facecolor=COMPONENT_COLORS[component],
            edgecolor=EDGE_COLOR,
            linewidth=1.10,
        )
        for component in used
        if area_stacks[COMPONENTS.index(component)].sum() > 0.0
        or energy_stacks[COMPONENTS.index(component)].sum() > 0.0
    ]
    legend_labels = [
        component
        for component in used
        if area_stacks[COMPONENTS.index(component)].sum() > 0.0
        or energy_stacks[COMPONENTS.index(component)].sum() > 0.0
    ]
    fig.legend(
        legend_handles,
        legend_labels,
        loc="lower center",
        bbox_to_anchor=(0.5, -0.02),
        ncol=5,
        frameon=False,
        handlelength=1.05,
        handleheight=0.70,
        handletextpad=0.35,
        columnspacing=0.90,
        borderaxespad=0.0,
        labelcolor=TEXT_COLOR,
    )
    fig.tight_layout(rect=(0.0, 0.10, 1.0, 1.0), pad=0.20, w_pad=0.80)
    save_figure(fig, FIGURE_STEM)
    print("Normalization: Baseline total = 1.0")
    print("Bucket/Ours area counts half of u_fp_acc; power uses the synthesized PE as reported.")
    print(f"Saved: {FIGURE_STEM.with_suffix('.png')}")
    print(f"Saved: {FIGURE_STEM.with_suffix('.pdf')}")


if __name__ == "__main__":
    plot_comparison()
