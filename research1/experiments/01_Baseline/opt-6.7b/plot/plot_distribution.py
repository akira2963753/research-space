#!/usr/bin/env python3
"""Render publication-quality OPT-6.7B FP16 distribution figures."""

from __future__ import annotations

import argparse
import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import matplotlib as mpl
import matplotlib.pyplot as plt
import numpy as np
from matplotlib import font_manager
from matplotlib.colors import LinearSegmentedColormap, PowerNorm
from matplotlib.ticker import FuncFormatter, MaxNLocator, ScalarFormatter


SCRIPT_DIR = Path(__file__).resolve().parent
DEFAULT_INPUT = SCRIPT_DIR.parent / "result" / "opt-6.7b-fp16-distribution.json"
DEFAULT_OUTPUT_DIR = SCRIPT_DIR / "figures"
DEFAULT_FONT = (
    SCRIPT_DIR.parent.parent / "llama2-7b" / "plot" / "fonts" / "EBGaramond-Bold.ttf"
)

WEIGHT_CMAP = LinearSegmentedColormap.from_list(
    "paper_blue", ["#E6F0F8", "#8FBBDD", "#347FB5", "#06365D"]
)
ACTIVATION_CMAP = LinearSegmentedColormap.from_list(
    "paper_crimson", ["#FCE7EA", "#ED929F", "#C7374F", "#6D0018"]
)


@dataclass(frozen=True)
class SurfaceData:
    values: np.ndarray
    x: np.ndarray
    y: np.ndarray
    x_label: str
    y_label: str
    title: str
    cmap: LinearSegmentedColormap


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Plot OPT-6.7B FP16 weight and activation distributions."
    )
    parser.add_argument("--input", type=Path, default=DEFAULT_INPUT)
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT_DIR)
    parser.add_argument("--font", type=Path, default=DEFAULT_FONT)
    parser.add_argument("--layers", type=int, nargs="*", default=None)
    parser.add_argument("--max-rows", type=int, default=96)
    parser.add_argument("--max-cols", type=int, default=344)
    parser.add_argument("--png-dpi", type=int, default=600)
    parser.add_argument(
        "--relative-only",
        action="store_true",
        help="Render only relative-outlier figures and skip magnitude figures.",
    )
    return parser.parse_args()


def configure_style(font_path: Path) -> font_manager.FontProperties:
    if not font_path.is_file():
        raise FileNotFoundError(f"EB Garamond Bold was not found at {font_path}")
    font_manager.fontManager.addfont(str(font_path))
    font_prop = font_manager.FontProperties(fname=str(font_path))
    family = font_prop.get_name()
    mpl.rcParams.update(
        {
            "font.family": family,
            "font.weight": "bold",
            "axes.labelweight": "bold",
            "axes.titleweight": "bold",
            "pdf.fonttype": 42,
            "ps.fonttype": 42,
            "savefig.facecolor": "white",
            "figure.facecolor": "white",
        }
    )
    return font_prop


def load_and_validate(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as input_file:
        payload = json.load(input_file)
    if payload.get("schema_version", 0) < 3:
        raise ValueError("Schema version 3 or newer is required.")
    if payload.get("experiment") != "fp16_weight_activation_distribution":
        raise ValueError("Unexpected experiment type.")
    if payload.get("model") != "facebook/opt-6.7b":
        raise ValueError(f"Unexpected model: {payload.get('model')}")
    profile = payload.get("profile", {})
    if profile.get("module") != "fc1":
        raise ValueError("Expected an fc1 distribution profile.")
    if profile.get("input_channel_stride") != 1:
        raise ValueError("Complete-channel data with input_channel_stride=1 is required.")
    if not profile.get("complete_input_channels_retained", False):
        raise ValueError("JSON does not confirm complete input-channel retention.")
    required_checks = (
        "activation_capture_closure_passed",
        "surface_shape_closure_passed",
        "tensor_statistics_closure_passed",
        "all_values_finite",
    )
    if not all(payload.get("validation", {}).get(key) is True for key in required_checks):
        raise ValueError("One or more notebook validation checks did not pass.")
    if not payload.get("layers"):
        raise ValueError("JSON contains no layer records.")
    return payload


def surface_from_layer(layer: dict[str, Any], kind: str) -> SurfaceData:
    if kind == "weight":
        raw = layer["weight_surface"]
        y_key = "output_channel_indices"
        y_label = "Output channel"
        title = "Weight"
        cmap = WEIGHT_CMAP
    elif kind == "activation":
        raw = layer["activation_surface"]
        y_key = "token_positions"
        y_label = "Token position"
        title = "Activation"
        cmap = ACTIVATION_CMAP
    else:
        raise ValueError(f"Unsupported surface kind: {kind}")

    values = np.abs(np.asarray(raw["values"], dtype=np.float32))
    x = np.asarray(raw["input_channel_indices"], dtype=np.float64)
    y = np.asarray(raw[y_key], dtype=np.float64)
    if values.shape != (y.size, x.size):
        raise ValueError(f"{kind} surface shape does not match its axes.")
    if not np.isfinite(values).all():
        raise ValueError(f"{kind} surface contains NaN or Inf.")
    return SurfaceData(values, x, y, "Input channel", y_label, title, cmap)


def block_max_pool(
    values: np.ndarray,
    x: np.ndarray,
    y: np.ndarray,
    max_rows: int,
    max_cols: int,
) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    if max_rows < 2 or max_cols < 2:
        raise ValueError("--max-rows and --max-cols must both be at least 2.")
    rows, cols = values.shape
    row_factor = max(1, int(np.ceil(rows / max_rows)))
    col_factor = max(1, int(np.ceil(cols / max_cols)))
    pooled_rows = int(np.ceil(rows / row_factor))
    pooled_cols = int(np.ceil(cols / col_factor))
    padded = np.full(
        (pooled_rows * row_factor, pooled_cols * col_factor),
        -np.inf,
        dtype=values.dtype,
    )
    padded[:rows, :cols] = values
    pooled = padded.reshape(
        pooled_rows, row_factor, pooled_cols, col_factor
    ).max(axis=(1, 3))

    def centers(axis: np.ndarray, factor: int) -> np.ndarray:
        return np.asarray(
            [
                axis[start : min(start + factor, axis.size)].mean()
                for start in range(0, axis.size, factor)
            ],
            dtype=np.float64,
        )

    return pooled, centers(x, col_factor), centers(y, row_factor)


def set_tick_font(
    ax: mpl.axes.Axes, font_prop: font_manager.FontProperties
) -> None:
    for tick in (*ax.get_xticklabels(), *ax.get_yticklabels(), *ax.get_zticklabels()):
        tick.set_fontproperties(font_prop)
        tick.set_fontsize(9.5)


def style_axis(
    ax: mpl.axes.Axes,
    data: SurfaceData,
    panel_title: str,
    z_label: str,
    font_prop: font_manager.FontProperties,
) -> None:
    ax.set_xlabel(data.x_label, labelpad=8, fontsize=11.5, fontproperties=font_prop)
    ax.set_ylabel(data.y_label, labelpad=15, fontsize=11.5, fontproperties=font_prop)
    ax.set_zlabel(z_label, labelpad=10, fontsize=11.5, fontproperties=font_prop)
    ax.text2D(
        0.5,
        0.965,
        panel_title,
        transform=ax.transAxes,
        fontsize=13.5,
        fontproperties=font_prop,
        va="top",
        ha="center",
    )
    ax.view_init(elev=25, azim=-59)
    ax.set_box_aspect((1.65, 1.0, 0.85))
    ax.xaxis.set_major_locator(MaxNLocator(nbins=5, integer=True))
    ax.yaxis.set_major_locator(MaxNLocator(nbins=5, integer=True))
    channel_formatter = FuncFormatter(
        lambda value, _: f"{value / 1000:g}k" if abs(value) >= 1000 else f"{value:.0f}"
    )
    ax.xaxis.set_major_formatter(channel_formatter)
    for axis in (ax.xaxis, ax.yaxis, ax.zaxis):
        axis.set_rotate_label(True)
        axis.pane.set_facecolor((0.985, 0.985, 0.985, 1.0))
        axis.pane.set_edgecolor((0.80, 0.80, 0.80, 1.0))
        axis._axinfo["grid"].update(
            {"color": (0.73, 0.73, 0.73, 0.55), "linewidth": 0.65}
        )
    if data.y_label == "Output channel":
        ax.yaxis.set_major_formatter(channel_formatter)
        ax.yaxis.offsetText.set_visible(False)
    else:
        formatter = ScalarFormatter(useMathText=False)
        formatter.set_powerlimits((-3, 4))
        ax.yaxis.set_major_formatter(formatter)
    ax.tick_params(axis="both", which="major", pad=0, width=0.8, length=3)
    set_tick_font(ax, font_prop)


def draw_surface(
    ax: mpl.axes.Axes,
    data: SurfaceData,
    values: np.ndarray,
    max_rows: int,
    max_cols: int,
    z_max: float,
) -> tuple[int, int]:
    pooled, pooled_x, pooled_y = block_max_pool(
        values, data.x, data.y, max_rows, max_cols
    )
    grid_x, grid_y = np.meshgrid(pooled_x, pooled_y)
    color_max = max(float(values.max()), np.finfo(float).eps)
    ax.plot_surface(
        grid_x,
        grid_y,
        pooled,
        cmap=data.cmap,
        norm=PowerNorm(gamma=0.38, vmin=0.0, vmax=color_max),
        rcount=pooled.shape[0],
        ccount=pooled.shape[1],
        linewidth=0,
        antialiased=False,
        shade=False,
        rasterized=True,
    )
    ax.set_xlim(float(data.x.min()), float(data.x.max()))
    ax.set_ylim(float(data.y.min()), float(data.y.max()))
    ax.set_zlim(0.0, z_max)
    return pooled.shape


def save_figure(
    figure: mpl.figure.Figure, output_dir: Path, stem: str, dpi: int
) -> tuple[Path, Path]:
    png_path = output_dir / f"{stem}.png"
    pdf_path = output_dir / f"{stem}.pdf"
    figure.savefig(png_path, dpi=dpi)
    figure.savefig(pdf_path, dpi=dpi)
    plt.close(figure)
    return png_path, pdf_path


def relative_severity(values: np.ndarray, p99: float) -> np.ndarray:
    if p99 <= 0.0:
        raise ValueError("P99 must be positive.")
    return np.log2(np.maximum(values / p99, 1.0)).astype(np.float32)


def render_relative(
    layers: list[dict[str, Any]],
    output_dir: Path,
    font_prop: font_manager.FontProperties,
    max_rows: int,
    max_cols: int,
    dpi: int,
) -> list[dict[str, Any]]:
    prepared = []
    for layer in layers:
        weight = surface_from_layer(layer, "weight")
        activation = surface_from_layer(layer, "activation")
        weight_p99 = float(layer["weight_tensor_statistics"]["p99_abs"])
        activation_p99 = float(layer["activation_tensor_statistics"]["p99_abs"])
        prepared.append(
            {
                "layer": layer,
                "weight": weight,
                "activation": activation,
                "weight_p99": weight_p99,
                "activation_p99": activation_p99,
                "weight_values": relative_severity(weight.values, weight_p99),
                "activation_values": relative_severity(activation.values, activation_p99),
            }
        )
    common_z_max = float(
        max(1, np.ceil(max(max(item["weight_values"].max(), item["activation_values"].max()) for item in prepared)))
    )
    results = []
    for item in prepared:
        layer_index = int(item["layer"]["layer_index"])
        figure = plt.figure(figsize=(13.2, 5.05), constrained_layout=False)
        weight_ax = figure.add_subplot(1, 2, 1, projection="3d")
        activation_ax = figure.add_subplot(1, 2, 2, projection="3d")
        weight_shape = draw_surface(
            weight_ax, item["weight"], item["weight_values"], max_rows, max_cols, common_z_max
        )
        activation_shape = draw_surface(
            activation_ax,
            item["activation"],
            item["activation_values"],
            max_rows,
            max_cols,
            common_z_max,
        )
        style_axis(
            weight_ax,
            item["weight"],
            f"(a)  Layer {layer_index} · Weight",
            "Outlier Severity (log₂ ratio)",
            font_prop,
        )
        style_axis(
            activation_ax,
            item["activation"],
            f"(b)  Layer {layer_index} · Activation",
            "Outlier Severity (log₂ ratio)",
            font_prop,
        )
        figure.subplots_adjust(left=0.012, right=0.992, bottom=0.035, top=0.995, wspace=-0.02)
        stem = f"opt_6_7b_fp16_layer{layer_index:02d}_relative_outlier"
        png_path, pdf_path = save_figure(figure, output_dir, stem, dpi)
        results.append(
            {
                "layer_index": layer_index,
                "weight_p99": item["weight_p99"],
                "activation_p99": item["activation_p99"],
                "common_z_axis": [0.0, common_z_max],
                "weight_display_shape": list(weight_shape),
                "activation_display_shape": list(activation_shape),
                "png": str(png_path),
                "pdf": str(pdf_path),
            }
        )
        print(f"Rendered relative outlier layer {layer_index}: {png_path}")
    return results


def render_magnitude(
    layers: list[dict[str, Any]],
    output_dir: Path,
    font_prop: font_manager.FontProperties,
    max_rows: int,
    max_cols: int,
    dpi: int,
) -> list[dict[str, Any]]:
    results = []
    for layer in layers:
        layer_index = int(layer["layer_index"])
        weight = surface_from_layer(layer, "weight")
        activation = surface_from_layer(layer, "activation")
        activation_z_max = max(float(activation.values.max()) * 1.04, 1e-6)
        figure = plt.figure(figsize=(13.2, 5.05), constrained_layout=False)
        weight_ax = figure.add_subplot(1, 2, 1, projection="3d")
        activation_ax = figure.add_subplot(1, 2, 2, projection="3d")
        weight_shape = draw_surface(weight_ax, weight, weight.values, max_rows, max_cols, 4.0)
        activation_shape = draw_surface(
            activation_ax,
            activation,
            activation.values,
            max_rows,
            max_cols,
            activation_z_max,
        )
        style_axis(weight_ax, weight, "(a)  Weight magnitude", "Magnitude", font_prop)
        style_axis(
            activation_ax, activation, "(b)  Activation magnitude", "Magnitude", font_prop
        )
        weight_ax.set_zticks([0.0, 1.0, 2.0, 3.0, 4.0])
        activation_ax.zaxis.set_major_locator(MaxNLocator(nbins=4))
        set_tick_font(weight_ax, font_prop)
        set_tick_font(activation_ax, font_prop)
        figure.subplots_adjust(left=0.012, right=0.992, bottom=0.035, top=0.995, wspace=-0.02)
        stem = f"opt_6_7b_fp16_layer{layer_index:02d}_distribution"
        png_path, pdf_path = save_figure(figure, output_dir, stem, dpi)
        results.append(
            {
                "layer_index": layer_index,
                "layer_name": layer["layer_name"],
                "weight_z_axis": [0.0, 4.0],
                "weight_z_ticks": [0.0, 1.0, 2.0, 3.0, 4.0],
                "weight_max": float(weight.values.max()),
                "activation_max": float(activation.values.max()),
                "weight_display_shape": list(weight_shape),
                "activation_display_shape": list(activation_shape),
                "png": str(png_path),
                "pdf": str(pdf_path),
            }
        )
        print(f"Rendered magnitude layer {layer_index}: {png_path}")
    return results


def main() -> None:
    args = parse_args()
    font_prop = configure_style(args.font.resolve())
    payload = load_and_validate(args.input.resolve())
    args.output_dir.mkdir(parents=True, exist_ok=True)

    selected = set(args.layers) if args.layers is not None else None
    layers = [
        layer
        for layer in payload["layers"]
        if selected is None or int(layer["layer_index"]) in selected
    ]
    if not layers:
        raise ValueError("No requested layer was found in the JSON.")
    if selected is not None:
        found = {int(layer["layer_index"]) for layer in layers}
        if selected != found:
            raise ValueError(f"Missing layers: {sorted(selected - found)}")

    relative_results = render_relative(
        layers,
        args.output_dir.resolve(),
        font_prop,
        args.max_rows,
        args.max_cols,
        args.png_dpi,
    )
    magnitude_results = []
    if not args.relative_only:
        magnitude_results = render_magnitude(
            layers,
            args.output_dir.resolve(),
            font_prop,
            args.max_rows,
            args.max_cols,
            args.png_dpi,
        )

    manifest = {
        "source_json": str(args.input.resolve()),
        "model": payload["model"],
        "model_revision": payload.get("model_revision"),
        "activation_location": payload["profile"]["activation_location"],
        "complete_input_channels_retained": True,
        "font": str(args.font.resolve()),
        "font_weight": 700,
        "png_dpi": args.png_dpi,
        "pooling": "block_max_for_rendering_only",
        "relative_outlier_definition": "max(0, log2(abs(value) / complete_tensor_p99))",
        "normalization_scope": "per_layer_per_kind_complete_tensor_p99",
        "magnitude_weight_z_axis": [0.0, 4.0],
        "relative_outlier_figures": relative_results,
        "absolute_magnitude_figures": magnitude_results,
    }
    manifest_path = args.output_dir.resolve() / "figure_manifest.json"
    with manifest_path.open("w", encoding="utf-8") as output_file:
        json.dump(manifest, output_file, indent=2, ensure_ascii=False)
    print(f"Wrote manifest: {manifest_path}")


if __name__ == "__main__":
    main()
