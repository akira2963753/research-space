from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import matplotlib.pyplot as plt
import numpy as np
from matplotlib.ticker import FormatStrFormatter, MultipleLocator


PLOT_DIR = Path(__file__).resolve().parent
RESEARCH_ROOT = PLOT_DIR.parents[1]
RESULT_PATH = (
    RESEARCH_ROOT
    / "experiments"
    / "11_DEW_ACC_Bitwidth_Overflow"
    / "llama2-7b"
    / "dew_acc_bitwidth_overflow.json"
)
FIGURE_DIR = PLOT_DIR / "figures"
FIGURE_STEM = FIGURE_DIR / "dew_acc_activity_area_tradeoff"
EXPECTED_WIDTHS = tuple(range(12, 33))


def load_json(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as file:
        return json.load(file)


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


def load_series() -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    payload = load_json(RESULT_PATH)
    global_rows = {
        int(row["acc_width"]): row for row in payload["global_by_width"]
    }
    area_rows = {
        int(width): row for width, row in payload["area_by_width"].items()
    }
    if set(global_rows) != set(EXPECTED_WIDTHS):
        raise ValueError("Overflow result does not cover W12-W32.")
    if set(area_rows) != set(EXPECTED_WIDTHS):
        raise ValueError("Area result does not cover W12-W32.")

    widths = np.asarray(EXPECTED_WIDTHS, dtype=np.int64)
    activity = np.asarray(
        [
            global_rows[width]["counts"]["overflow_event_count"]
            for width in EXPECTED_WIDTHS
        ],
        dtype=np.float64,
    )
    pe_area = np.asarray(
        [area_rows[width]["total_pe_area"] for width in EXPECTED_WIDTHS],
        dtype=np.float64,
    )
    if activity[0] <= 0.0 or pe_area[0] <= 0.0:
        raise ValueError("W12 normalization reference must be positive.")
    return widths, activity / activity[0], pe_area / pe_area[0]


def plot_tradeoff() -> None:
    widths, normalized_activity, normalized_area = load_series()
    configure_ieee_style()

    fig, activity_ax = plt.subplots(figsize=(3.55, 2.15))
    area_ax = activity_ax.twinx()

    activity_line = activity_ax.plot(
        widths,
        normalized_activity,
        color="#4C78A8",
        linewidth=1.25,
        linestyle="-",
        marker="o",
        markersize=4.1,
        markerfacecolor="#4C78A8",
        markeredgecolor="0.20",
        markeredgewidth=0.55,
        label="FP-Acc Activity",
        zorder=3,
    )[0]
    area_line = area_ax.plot(
        widths,
        normalized_area,
        color="#D17C2F",
        linewidth=1.25,
        linestyle="-",
        marker="s",
        markersize=3.9,
        markerfacecolor="#D17C2F",
        markeredgecolor="0.20",
        markeredgewidth=0.55,
        label="PE Area",
        zorder=3,
    )[0]

    activity_ax.set_xlabel("DEW-Acc bit-width (bits)")
    activity_ax.set_ylabel("Normalized FP-Acc Activity")
    area_ax.set_ylabel("Normalized PE Area")
    activity_ax.set_xticks(np.arange(12, 33, 2))
    activity_ax.set_xlim(11.7, 32.3)
    activity_ax.set_ylim(-0.035, 1.08)
    area_ax.set_ylim(0.98, float(normalized_area.max()) + 0.035)
    activity_ax.yaxis.set_major_locator(MultipleLocator(0.2))
    area_ax.yaxis.set_major_locator(MultipleLocator(0.05))
    activity_ax.yaxis.set_major_formatter(FormatStrFormatter("%.1f"))
    area_ax.yaxis.set_major_formatter(FormatStrFormatter("%.2f"))

    activity_ax.grid(
        axis="y",
        color="0.84",
        linewidth=0.55,
        linestyle="--",
        zorder=0,
    )
    activity_ax.spines["top"].set_visible(False)
    activity_ax.spines["right"].set_visible(False)
    area_ax.spines["top"].set_visible(False)
    area_ax.spines["left"].set_visible(False)
    activity_ax.tick_params(direction="in", top=False, right=False)
    area_ax.tick_params(direction="in", top=False, left=False)

    activity_ax.legend(
        handles=[activity_line, area_line],
        loc="upper center",
        ncol=2,
        frameon=True,
        fancybox=True,
        framealpha=0.92,
        facecolor="white",
        edgecolor="0.75",
        handlelength=1.65,
        columnspacing=0.85,
        labelspacing=0.26,
        borderpad=0.45,
        borderaxespad=0.35,
    )

    fig.tight_layout(pad=0.35)
    save_figure(fig, FIGURE_STEM)
    print(f"Source: {RESULT_PATH}")
    print("Normalization: W12 = 1.0 for both series")
    print(f"Saved: {FIGURE_STEM.with_suffix('.png')}")
    print(f"Saved: {FIGURE_STEM.with_suffix('.pdf')}")


if __name__ == "__main__":
    plot_tradeoff()
