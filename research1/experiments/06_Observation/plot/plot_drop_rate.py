"""Plot the DEWA drop rate with and without activation-outlier separation."""

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
from matplotlib.ticker import FuncFormatter, LogLocator, NullFormatter


PATH_STYLES = {
    "Without outlier separation": ("#4C78A8", "o"),
    "With outlier separation": ("#F28E2B", "s"),
}
INPUT_NAME = (
    "llama2-7b-w-bfp4-a-bfp4-vs-bie4-3sigma-uncapped-g16-in-window-blkexp-runmax-"
    "b8-ts1-out1024.json"
)


@dataclass(frozen=True)
class DropProfile:
    """Drop rates of normal partial sums per T_drop."""

    t_drop: tuple[int, ...]
    raw: tuple[float, ...]
    separated: tuple[float, ...]
    t_replace: int
    group_size: int
    num_layers: int


def require(mapping: dict[str, Any], key: str, path: Path) -> Any:
    if key not in mapping:
        raise KeyError(f"Missing '{key}' in {path}")
    return mapping[key]


def drop_rate(hist: list[int], limit: int, t_drop: int) -> float:
    """Share of decisions with delta_E <= -t_drop; bin i holds delta_E = i - (limit + 1)."""
    if not 1 <= t_drop <= limit:
        raise ValueError(f"T_drop={t_drop} is outside the histogram range")
    total = sum(hist)
    if total <= 0:
        raise ValueError("Empty delta_E histogram")
    dropped = sum(count for index, count in enumerate(hist) if index - (limit + 1) <= -t_drop)
    return dropped / total


def load_profile(path: Path, t_drop_values: tuple[int, ...]) -> DropProfile:
    with path.open("r", encoding="utf-8") as file:
        payload = json.load(file)

    metadata = require(payload, "metadata", path)
    aggregate = require(payload, "aggregate", path)
    limit = int(require(require(metadata, "profile_config", path), "delta_bin_limit", path))
    bfp_config = require(metadata, "bfp_config", path)
    if 1 + int(require(bfp_config, "mantissa_bits", path)) != 4:
        raise ValueError(f"Expected a BFP4 profile in {path}")

    hists = {}
    for section in ("raw", "separated"):
        hist = [int(v) for v in require(require(aggregate, section, path), "delta_hist", path)]
        decisions = int(aggregate[section]["counts"]["nonzero_decisions"])
        if len(hist) != 2 * limit + 3 or sum(hist) != decisions:
            raise ValueError(f"Histogram does not match decision count for {section}")
        hists[section] = hist

    # The separated histogram holds normal partial sums only, so its drop rate excludes P_O.
    return DropProfile(
        t_drop=t_drop_values,
        raw=tuple(drop_rate(hists["raw"], limit, t) for t in t_drop_values),
        separated=tuple(drop_rate(hists["separated"], limit, t) for t in t_drop_values),
        t_replace=3,
        group_size=int(require(bfp_config, "block_size", path)),
        num_layers=int(require(aggregate, "num_layers", path)),
    )


def configure_ieee_style() -> None:
    plt.rcParams.update(
        {
            "font.family": "serif",
            "font.serif": ["Times New Roman", "Times", "DejaVu Serif"],
            "mathtext.fontset": "stix",
            "font.size": 8,
            "axes.labelsize": 8,
            "axes.titlesize": 8,
            "xtick.labelsize": 7,
            "ytick.labelsize": 7,
            "legend.fontsize": 7,
            "axes.linewidth": 0.6,
            "xtick.major.width": 0.6,
            "ytick.major.width": 0.6,
            "ytick.minor.width": 0.45,
            "xtick.major.size": 2.6,
            "ytick.major.size": 2.6,
            "ytick.minor.size": 1.5,
            "pdf.fonttype": 42,
            "ps.fonttype": 42,
            "savefig.facecolor": "white",
        }
    )


def finish_axis(ax: plt.Axes) -> None:
    ax.grid(axis="y", which="major", color="0.84", linewidth=0.55, linestyle="--", zorder=0)
    ax.spines["top"].set_visible(False)
    ax.spines["right"].set_visible(False)
    ax.tick_params(direction="in", which="both", top=False, right=False)


def percent_label(value: float, _position: int) -> str:
    return f"{value:g}"


def save_figure(fig: plt.Figure, output_dir: Path, stem: str) -> None:
    output_dir.mkdir(parents=True, exist_ok=True)
    png_path = output_dir / f"{stem}.png"
    pdf_path = output_dir / f"{stem}.pdf"
    fig.savefig(png_path, dpi=600, bbox_inches="tight")
    fig.savefig(pdf_path, bbox_inches="tight")
    plt.close(fig)
    print(f"Saved: {png_path}")
    print(f"Saved: {pdf_path}")


def plot_drop_rate(profile: DropProfile, output_dir: Path, design_t_drop: int) -> None:
    x = np.asarray(profile.t_drop, dtype=np.int64)
    series = {
        "Without outlier separation": 100.0 * np.asarray(profile.raw),
        "With outlier separation": 100.0 * np.asarray(profile.separated),
    }

    fig, ax = plt.subplots(figsize=(3.5, 2.3))
    for label, values in series.items():
        color, marker = PATH_STYLES[label]
        ax.plot(
            x,
            values,
            color=color,
            linewidth=1.2,
            marker=marker,
            markersize=4.0,
            markerfacecolor=color,
            markeredgecolor="0.20",
            markeredgewidth=0.5,
            label=label,
            zorder=3,
        )

    if design_t_drop in profile.t_drop:
        index = profile.t_drop.index(design_t_drop)
        high = series["Without outlier separation"][index]
        low = series["With outlier separation"][index]
        ax.axvline(design_t_drop, color="0.45", linewidth=0.7, linestyle=":", zorder=1)
        ax.annotate(
            "",
            xy=(design_t_drop + 0.18, low),
            xytext=(design_t_drop + 0.18, high),
            arrowprops={"arrowstyle": "<->", "color": "0.25", "linewidth": 0.6,
                        "shrinkA": 1.5, "shrinkB": 1.5},
        )
        ax.text(
            design_t_drop + 0.28,
            np.sqrt(high * low),
            f"{high / low:.0f}" + r"$\times$",
            fontsize=7,
            va="center",
            ha="left",
        )

    ax.set_yscale("log")
    ax.yaxis.set_major_locator(LogLocator(base=10.0))
    ax.yaxis.set_major_formatter(FuncFormatter(percent_label))
    ax.yaxis.set_minor_locator(LogLocator(base=10.0, subs=np.arange(2, 10)))
    ax.yaxis.set_minor_formatter(NullFormatter())
    ax.set_xlim(x[0] - 0.3, x[-1] + 0.6)
    ax.set_xticks(x)
    ax.set_xlabel(r"$T_{\mathrm{drop}}$")
    ax.set_ylabel("Dropped partial sums (%)")

    finish_axis(ax)
    ax.legend(
        frameon=False,
        loc="lower left",
        handlelength=1.5,
        handletextpad=0.5,
        labelspacing=0.3,
        borderaxespad=0.2,
    )
    fig.tight_layout(pad=0.3)
    save_figure(fig, output_dir / f"g{profile.group_size}", "drop_rate_vs_tdrop")


def print_summary(profile: DropProfile) -> None:
    print(f"BFP4, Group-{profile.group_size}, {profile.num_layers} Linear layers")
    print("T_drop  Without (%)   With (%)   Ratio")
    for t, raw, sep in zip(profile.t_drop, profile.raw, profile.separated):
        ratio = f"{raw / sep:8.1f}x" if sep else "     inf"
        print(f"{t:>6}  {100 * raw:10.5f}  {100 * sep:9.5f}  {ratio}")


def main() -> None:
    script_path = Path(__file__).resolve()
    observation_root = script_path.parents[1]
    parser = argparse.ArgumentParser(description="Plot DEWA drop rate versus T_drop.")
    parser.add_argument(
        "--input",
        type=Path,
        default=observation_root / "llama2-7b" / INPUT_NAME,
    )
    parser.add_argument("--output-dir", type=Path, default=script_path.parent / "figures")
    parser.add_argument("--t-drop-min", type=int, default=4)
    parser.add_argument("--t-drop-max", type=int, default=10)
    parser.add_argument("--design-t-drop", type=int, default=9)
    args = parser.parse_args()

    if args.t_drop_min > args.t_drop_max:
        raise ValueError("--t-drop-min must not exceed --t-drop-max")
    t_drop_values = tuple(range(args.t_drop_min, args.t_drop_max + 1))

    configure_ieee_style()
    profile = load_profile(args.input, t_drop_values)
    print_summary(profile)
    plot_drop_rate(profile, args.output_dir, args.design_t_drop)


if __name__ == "__main__":
    main()
