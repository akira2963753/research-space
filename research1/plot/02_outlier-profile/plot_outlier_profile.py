"""Plot DEWA activation-outlier profiling results."""

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
from matplotlib.ticker import MaxNLocator


PATH_STYLES = {
    "Raw": ("#4C78A8", "o"),
    "Outlier-separated": ("#F28E2B", "s"),
}


@dataclass(frozen=True)
class ThresholdMetrics:
    """Raw and outlier-separated DEWA rates at one threshold."""

    threshold: int
    raw_in_window: float
    clean_in_window: float


@dataclass(frozen=True)
class RateCount:
    """One exact numerator/denominator rate."""

    numerator: int
    denominator: int

    @property
    def rate(self) -> float:
        return self.numerator / self.denominator


@dataclass(frozen=True)
class Profile:
    """Validated values required by the outlier-profile plots."""

    bfp_bits: int
    group_size: int
    num_layers: int
    thresholds: tuple[ThresholdMetrics, ...]
    outlier_lane: RateCount
    outlier_group: RateCount


def require(mapping: dict[str, Any], key: str, path: Path) -> Any:
    if key not in mapping:
        raise KeyError(f"Missing '{key}' in {path}")
    return mapping[key]


def threshold_index(
    records: list[dict[str, Any]],
    path: Path,
) -> dict[int, dict[str, Any]]:
    indexed: dict[int, dict[str, Any]] = {}
    for record in records:
        threshold = int(require(record, "threshold", path))
        if threshold in indexed:
            raise ValueError(f"Duplicate threshold T={threshold} in {path}")
        indexed[threshold] = record
    return indexed


def sum_rate(
    records: list[dict[str, Any]],
    section: str,
    threshold: int,
    rate_name: str,
    path: Path,
) -> RateCount:
    numerator = 0
    denominator = 0
    for layer in records:
        path_records = threshold_index(layer["paths"][section], path)
        rate = path_records[threshold]["rates"][rate_name]
        numerator += int(require(rate, "numerator", path))
        denominator += int(require(rate, "denominator", path))
    if denominator <= 0 or not 0 <= numerator <= denominator:
        raise ValueError(f"Invalid {section}/{rate_name} total at T={threshold}")
    return RateCount(numerator=numerator, denominator=denominator)


def sum_exception_rate(
    records: list[dict[str, Any]],
    rate_name: str,
    path: Path,
) -> RateCount:
    numerator = sum(
        int(require(layer["exception_path_cost"][rate_name], "numerator", path))
        for layer in records
    )
    denominator = sum(
        int(require(layer["exception_path_cost"][rate_name], "denominator", path))
        for layer in records
    )
    if denominator <= 0 or not 0 <= numerator <= denominator:
        raise ValueError(f"Invalid exception-path total for {rate_name}")
    return RateCount(numerator=numerator, denominator=denominator)


def load_profile(path: Path, include_lm_head: bool) -> Profile:
    """Load one profile and aggregate the selected Linear-layer scope."""
    with path.open("r", encoding="utf-8") as file:
        payload = json.load(file)

    metadata = require(payload, "metadata", path)
    bfp_config = require(metadata, "bfp_config", path)
    group_size = int(require(bfp_config, "block_size", path))
    bfp_bits = 1 + int(require(bfp_config, "mantissa_bits", path))
    if bfp_bits != 4 or group_size <= 0:
        raise ValueError(f"Expected a valid BFP4 profile in {path}")

    all_layers = list(require(payload, "layers", path))
    layers = [
        layer
        for layer in all_layers
        if include_lm_head or str(require(layer, "layer_type", path)) != "lm_head"
    ]
    if not layers:
        raise ValueError(f"No selected layers in {path}")

    threshold_sets = []
    for layer in layers:
        raw = threshold_index(layer["paths"]["raw"], path)
        clean = threshold_index(layer["paths"]["clean"], path)
        if set(raw) != set(clean):
            raise ValueError(f"Threshold mismatch in {layer['layer_name']}")
        threshold_sets.append(set(raw))
    if any(items != threshold_sets[0] for items in threshold_sets[1:]):
        raise ValueError(f"Layer threshold sets differ in {path}")

    metrics = []
    for threshold in sorted(threshold_sets[0]):
        raw_in_window = sum_rate(
            layers,
            "raw",
            threshold,
            "normal_add_rate",
            path,
        )
        clean_in_window = sum_rate(
            layers,
            "clean",
            threshold,
            "normal_add_rate",
            path,
        )

        metrics.append(
            ThresholdMetrics(
                threshold=threshold,
                raw_in_window=raw_in_window.rate,
                clean_in_window=clean_in_window.rate,
            )
        )

    outlier_lane = sum_exception_rate(layers, "outlier_lane_rate", path)
    outlier_group = sum_exception_rate(layers, "outlier_group_rate", path)
    group_slots = sum_exception_rate(layers, "group_output_slot_rate", path)
    if not np.isclose(
        outlier_group.rate,
        group_slots.rate,
        rtol=0.0,
        atol=1e-15,
    ):
        raise ValueError(f"Affected-group and group-slot rates differ in {path}")

    return Profile(
        bfp_bits=bfp_bits,
        group_size=group_size,
        num_layers=len(layers),
        thresholds=tuple(metrics),
        outlier_lane=outlier_lane,
        outlier_group=outlier_group,
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
            "hatch.linewidth": 0.45,
            "pdf.fonttype": 42,
            "ps.fonttype": 42,
            "savefig.facecolor": "white",
        }
    )


def finish_axis(ax: plt.Axes, grid_axis: str = "y") -> None:
    ax.grid(axis=grid_axis, color="0.84", linewidth=0.55, linestyle="--", zorder=0)
    ax.spines["top"].set_visible(False)
    ax.spines["right"].set_visible(False)
    ax.tick_params(direction="in", top=False, right=False)


def save_figure(fig: plt.Figure, output_dir: Path, stem: str) -> None:
    output_dir.mkdir(parents=True, exist_ok=True)
    png_path = output_dir / f"{stem}.png"
    pdf_path = output_dir / f"{stem}.pdf"
    fig.savefig(png_path, dpi=600, bbox_inches="tight")
    fig.savefig(pdf_path, bbox_inches="tight")
    plt.close(fig)
    print(f"Saved: {png_path}")
    print(f"Saved: {pdf_path}")


def plot_in_window_rate(
    profile: Profile,
    output_dir: Path,
    y_min: float,
) -> None:
    """Plot Raw and outlier-separated DEWA in-window rates."""
    thresholds = np.asarray(
        [item.threshold for item in profile.thresholds],
        dtype=np.int64,
    )
    raw = 100.0 * np.asarray(
        [item.raw_in_window for item in profile.thresholds],
        dtype=np.float64,
    )
    clean = 100.0 * np.asarray(
        [item.clean_in_window for item in profile.thresholds],
        dtype=np.float64,
    )
    fig, ax = plt.subplots(figsize=(3.5, 2.3))
    for label, values in (
        ("Raw", raw),
        ("Outlier-separated", clean),
    ):
        color, marker = PATH_STYLES[label]
        ax.plot(
            thresholds,
            values,
            color=color,
            linewidth=1.2,
            linestyle="-",
            marker=marker,
            markersize=4.0,
            markerfacecolor=color,
            markeredgecolor="0.20",
            markeredgewidth=0.5,
            label=label,
            zorder=3,
        )

    ax.set_xlim(thresholds[0] - 0.25, thresholds[-1] + 0.25)
    ax.set_ylim(y_min, 100.1)
    ax.set_xticks(thresholds)
    ax.set_xlabel(r"DEWA Threshold ($T$)")
    ax.set_ylabel("In-window rate (%)")
    ax.yaxis.set_major_locator(MaxNLocator(nbins=5))

    finish_axis(ax)
    ax.legend(
        frameon=False,
        loc="center right",
        handlelength=1.5,
        handletextpad=0.5,
        labelspacing=0.3,
        borderaxespad=0.2,
    )
    fig.tight_layout(pad=0.3)
    save_figure(
        fig,
        output_dir / f"g{profile.group_size}",
        "in_window_rate",
    )


def print_summary(profile: Profile) -> None:
    print(
        f"BFP{profile.bfp_bits}, Group-{profile.group_size}, "
        f"{profile.num_layers} Linear layers"
    )
    print("T  Raw in-window (%)  Outlier-separated in-window (%)  Gain (pp)")
    for item in profile.thresholds:
        print(
            f"{item.threshold:>2}  {100.0 * item.raw_in_window:>17.6f}  "
            f"{100.0 * item.clean_in_window:>31.6f}  "
            f"{100.0 * (item.clean_in_window - item.raw_in_window):>9.6f}"
        )
    print(f"Outlier lanes: {100.0 * profile.outlier_lane.rate:.6f}%")
    print(f"Affected groups: {100.0 * profile.outlier_group.rate:.6f}%")


def main() -> None:
    script_path = Path(__file__).resolve()
    research_root = script_path.parents[2]
    parser = argparse.ArgumentParser(
        description="Plot DEWA in-window rates for G16 and G32."
    )
    parser.add_argument(
        "--group-sizes",
        type=int,
        nargs="+",
        choices=(16, 32),
        default=(16, 32),
    )
    parser.add_argument("--input-root", type=Path, default=None)
    parser.add_argument("--output-dir", type=Path, default=None)
    parser.add_argument(
        "--include-lm-head",
        action="store_true",
        help="Include the legacy quantized LM Head record.",
    )
    args = parser.parse_args()

    input_root = (
        args.input_root
        if args.input_root is not None
        else (
            research_root
            / "experiments"
            / "05_DEW_Outlier_Profile"
            / "llama2-7b"
        )
    )
    output_dir = (
        args.output_dir
        if args.output_dir is not None
        else script_path.parent / "figures"
    )

    configure_ieee_style()
    group_sizes = tuple(dict.fromkeys(args.group_sizes))
    profiles = []
    for group_size in group_sizes:
        input_path = (
            input_root
            / f"g{group_size}"
            / f"bfp4-g{group_size}-t8-12.json"
        )
        profile = load_profile(input_path, include_lm_head=args.include_lm_head)
        if profile.group_size != group_size:
            raise ValueError(
                f"Input contains G{profile.group_size}, expected G{group_size}"
            )
        profiles.append(profile)
        print_summary(profile)

    minimum_rate = min(
        100.0 * min(item.raw_in_window, item.clean_in_window)
        for profile in profiles
        for item in profile.thresholds
    )
    shared_y_min = max(0.0, np.floor((minimum_rate - 0.5) * 2.0) / 2.0)
    for profile in profiles:
        plot_in_window_rate(profile, output_dir, shared_y_min)


if __name__ == "__main__":
    main()
