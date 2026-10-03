#!/usr/bin/env python3
"""Render publication-quality FP16 weight and activation distributions."""

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
DEFAULT_INPUT = SCRIPT_DIR.parent / "result" / "llama2-7b-fp16-distribution.json"
DEFAULT_OUTPUT_DIR = SCRIPT_DIR / "figures"
DEFAULT_FONT = SCRIPT_DIR / "fonts" / "EBGaramond-Bold.ttf"

WEIGHT_CMAP = LinearSegmentedColormap.from_list(
    "paper_blue",
    ["#E6F0F8", "#8FBBDD", "#347FB5", "#06365D"],
)
ACTIVATION_CMAP = LinearSegmentedColormap.from_list(
    "paper_crimson",
    ["#FCE7EA", "#ED929F", "#C7374F", "#6D0018"],
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
        description=(
            "Plot FP16 weight and activation relative-outlier surfaces from the "
            "LLaMA2-7B distribution JSON."
        )
    )
    parser.add_argument(
        "--input",
        type=Path,
        default=DEFAULT_INPUT,
        help=f"Distribution JSON. Default: {DEFAULT_INPUT}",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=DEFAULT_OUTPUT_DIR,
        help=f"Figure directory. Default: {DEFAULT_OUTPUT_DIR}",
    )
    parser.add_argument(
        "--font",
        type=Path,
        default=DEFAULT_FONT,
        help=f"EB Garamond Bold TTF. Default: {DEFAULT_FONT}",
    )
    parser.add_argument(
        "--layers",
        type=int,
        nargs="*",
        default=None,
        help="Layer indices to render. Default: every layer stored in the JSON.",
    )
    parser.add_argument(
        "--max-rows",
        type=int,
        default=96,
        help="Maximum displayed rows after block-max pooling. Default: 96.",
    )
    parser.add_argument(
        "--max-cols",
        type=int,
        default=344,
        help="Maximum displayed columns after block-max pooling. Default: 344.",
    )
    parser.add_argument(
        "--png-dpi",
        type=int,
        default=600,
        help="PNG and rasterized-surface resolution. Default: 600 DPI.",
    )
    parser.add_argument(
        "--include-absolute",
        action="store_true",
        help="Also render the optional absolute-magnitude figures.",
    )
    return parser.parse_args()


def configure_style(font_path: Path) -> font_manager.FontProperties:
    if not font_path.is_file():
        raise FileNotFoundError(
            f"EB Garamond Bold was not found at {font_path}. "
            "Keep the bundled font or pass --font PATH."
        )

    font_manager.fontManager.addfont(str(font_path))
    font_prop = font_manager.FontProperties(fname=str(font_path))
    family = font_prop.get_name()

    mpl.rcParams.update(
        {
            "font.family": family,
            "font.weight": "bold",
            "axes.titleweight": "bold",
            "axes.labelweight": "bold",
            "axes.linewidth": 0.9,
            "axes.edgecolor": "#202124",
            "xtick.color": "#202124",
            "ytick.color": "#202124",
            "text.color": "#202124",
            "figure.facecolor": "white",
            "axes.facecolor": "white",
            "savefig.facecolor": "white",
            "pdf.fonttype": 42,
            "ps.fonttype": 42,
            "pdf.compression": 9,
            "figure.dpi": 180,
            "savefig.bbox": "tight",
            "savefig.pad_inches": 0.06,
        }
    )
    return font_prop


def load_and_validate(path: Path) -> dict[str, Any]:
    if not path.is_file():
        raise FileNotFoundError(f"Distribution JSON was not found: {path}")

    with path.open("r", encoding="utf-8") as handle:
        payload = json.load(handle)

    required = {"schema_version", "experiment", "model", "layers", "validation"}
    missing = required.difference(payload)
    if missing:
        raise ValueError(f"JSON is missing required keys: {sorted(missing)}")
    if payload["experiment"] != "fp16_weight_activation_distribution":
        raise ValueError(f"Unexpected experiment: {payload['experiment']!r}")
    if int(payload["schema_version"]) < 2:
        raise ValueError(
            "This plot requires schema_version >= 2 with exact tensor-wise P99. "
            "Rerun distribution.ipynb before plotting."
        )
    if not payload["layers"]:
        raise ValueError("JSON contains no layer surfaces.")

    validation = payload["validation"]
    for key in (
        "activation_capture_closure_passed",
        "surface_shape_closure_passed",
        "tensor_statistics_closure_passed",
        "all_values_finite",
    ):
        if validation.get(key) is not True:
            raise ValueError(f"Input validation failed or is missing: {key}")

    for layer in payload["layers"]:
        for key in ("weight_tensor_statistics", "activation_tensor_statistics"):
            statistics = layer.get(key)
            if not statistics or float(statistics.get("p99_abs", 0.0)) <= 0.0:
                raise ValueError(
                    f"Layer {layer.get('layer_index')} is missing a positive {key}. "
                    "Rerun distribution.ipynb."
                )

    return payload


def _surface_from_layer(layer: dict[str, Any], kind: str) -> SurfaceData:
    if kind == "weight":
        raw = layer["weight_surface"]
        y_key = "output_channel_indices"
        title = "Weight magnitude"
        y_label = "Output channel"
        cmap = WEIGHT_CMAP
    elif kind == "activation":
        raw = layer["activation_surface"]
        y_key = "token_positions"
        title = "Activation magnitude"
        y_label = "Token position"
        cmap = ACTIVATION_CMAP
    else:
        raise ValueError(f"Unsupported surface kind: {kind}")

    values = np.abs(np.asarray(raw["values"], dtype=np.float32))
    x = np.asarray(raw["input_channel_indices"], dtype=np.float64)
    y = np.asarray(raw[y_key], dtype=np.float64)

    if values.ndim != 2:
        raise ValueError(f"{kind} surface must be 2-D, got {values.shape}")
    if values.shape != (y.size, x.size):
        raise ValueError(
            f"{kind} surface shape {values.shape} does not match "
            f"axes {(y.size, x.size)}"
        )
    if not np.isfinite(values).all():
        raise ValueError(f"{kind} surface contains NaN or Inf values")

    return SurfaceData(
        values=values,
        x=x,
        y=y,
        x_label="Input channel",
        y_label=y_label,
        title=title,
        cmap=cmap,
    )


def block_max_pool(
    values: np.ndarray,
    x: np.ndarray,
    y: np.ndarray,
    max_rows: int,
    max_cols: int,
) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """Pool display data while preserving local extrema and coordinate meaning."""
    if max_rows < 2 or max_cols < 2:
        raise ValueError("--max-rows and --max-cols must both be at least 2")

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
        pooled_rows,
        row_factor,
        pooled_cols,
        col_factor,
    ).max(axis=(1, 3))

    def pooled_centers(axis: np.ndarray, factor: int) -> np.ndarray:
        return np.asarray(
            [axis[start : min(start + factor, axis.size)].mean() for start in range(0, axis.size, factor)],
            dtype=np.float64,
        )

    return pooled, pooled_centers(x, col_factor), pooled_centers(y, row_factor)


def _set_tick_font(ax: mpl.axes.Axes, font_prop: font_manager.FontProperties) -> None:
    for tick in (*ax.get_xticklabels(), *ax.get_yticklabels(), *ax.get_zticklabels()):
        tick.set_fontproperties(font_prop)
        tick.set_fontsize(9.5)


def _format_index_tick(value: float, _position: int) -> str:
    """Use explicit channel/token labels and never Matplotlib's axis offset."""
    return f"{value / 1000:g}k" if abs(value) >= 1000 else f"{value:.0f}"


def _style_index_axes(ax: mpl.axes.Axes) -> None:
    formatter = FuncFormatter(_format_index_tick)
    ax.xaxis.set_major_formatter(formatter)
    ax.yaxis.set_major_formatter(formatter)
    # 3-D ScalarFormatter offsets such as "1e4" obscure output-channel indices.
    ax.xaxis.get_offset_text().set_visible(False)
    ax.yaxis.get_offset_text().set_visible(False)


def align_3d_axis_labels(ax: mpl.axes.Axes) -> None:
    """Rotate labels with the projected 3-D axes and keep them centered."""
    for axis in (ax.xaxis, ax.yaxis, ax.zaxis):
        axis.set_rotate_label(True)
    ax.xaxis.label.set_horizontalalignment("center")
    ax.yaxis.label.set_horizontalalignment("center")
    ax.xaxis.label.set_verticalalignment("center")
    ax.yaxis.label.set_verticalalignment("center")
    ax.zaxis.label.set_horizontalalignment("center")
    ax.zaxis.label.set_verticalalignment("center")


def style_3d_axis(
    ax: mpl.axes.Axes,
    data: SurfaceData,
    panel_label: str,
    font_prop: font_manager.FontProperties,
) -> None:
    ax.set_xlabel(data.x_label, labelpad=10, fontsize=13, fontproperties=font_prop)
    ax.set_ylabel(data.y_label, labelpad=18, fontsize=13, fontproperties=font_prop)
    ax.set_zlabel("Magnitude", labelpad=10, fontsize=13, fontproperties=font_prop)
    ax.text2D(
        0.5,
        0.965,
        f"{panel_label}  {data.title}",
        transform=ax.transAxes,
        fontsize=15.5,
        fontproperties=font_prop,
        va="top",
        ha="center",
    )

    ax.view_init(elev=25, azim=-59)
    ax.set_box_aspect((1.65, 1.0, 0.85))
    ax.xaxis.set_major_locator(MaxNLocator(nbins=5, integer=True))
    ax.yaxis.set_major_locator(MaxNLocator(nbins=5, integer=True))
    ax.zaxis.set_major_locator(MaxNLocator(nbins=4))
    _style_index_axes(ax)
    for axis in (ax.xaxis, ax.yaxis, ax.zaxis):
        if axis is ax.zaxis:
            formatter = ScalarFormatter(useMathText=False)
            formatter.set_powerlimits((-3, 4))
            axis.set_major_formatter(formatter)
        axis.pane.set_facecolor((0.985, 0.985, 0.985, 1.0))
        axis.pane.set_edgecolor((0.80, 0.80, 0.80, 1.0))
        axis._axinfo["grid"].update(
            {"color": (0.73, 0.73, 0.73, 0.55), "linewidth": 0.65}
        )
    ax.tick_params(axis="both", which="major", pad=0, width=0.8, length=3)
    align_3d_axis_labels(ax)
    _set_tick_font(ax, font_prop)


def draw_surface(
    ax: mpl.axes.Axes,
    data: SurfaceData,
    max_rows: int,
    max_cols: int,
    font_prop: font_manager.FontProperties,
) -> tuple[tuple[int, int], dict[str, float]]:
    pooled, pooled_x, pooled_y = block_max_pool(
        data.values,
        data.x,
        data.y,
        max_rows=max_rows,
        max_cols=max_cols,
    )
    grid_x, grid_y = np.meshgrid(pooled_x, pooled_y)
    z_max = float(data.values.max())
    normalizer = PowerNorm(gamma=0.38, vmin=0.0, vmax=max(z_max, np.finfo(float).eps))

    ax.plot_surface(
        grid_x,
        grid_y,
        pooled,
        cmap=data.cmap,
        norm=normalizer,
        rcount=pooled.shape[0],
        ccount=pooled.shape[1],
        linewidth=0,
        antialiased=False,
        shade=False,
        rasterized=True,
    )
    ax.set_xlim(float(data.x.min()), float(data.x.max()))
    ax.set_ylim(float(data.y.min()), float(data.y.max()))
    ax.set_zlim(0.0, z_max * 1.04 if z_max > 0 else 1.0)

    stats = {
        "p99": float(np.percentile(data.values, 99.0)),
        "p999": float(np.percentile(data.values, 99.9)),
        "max": z_max,
    }
    return pooled.shape, stats


def relative_outlier_severity(
    values: np.ndarray,
    p99: float,
) -> tuple[np.ndarray, float]:
    """Normalize sampled elements by the exact P99 of their complete tensor."""
    if p99 <= 0.0:
        raise ValueError("P99 must be positive for relative outlier normalization")
    severity = np.log2(np.maximum(values / p99, 1.0)).astype(np.float32)
    return severity, float(severity.max())


def style_relative_axis(
    ax: mpl.axes.Axes,
    data: SurfaceData,
    panel_title: str,
    z_max: float,
    font_prop: font_manager.FontProperties,
) -> None:
    ax.set_xlabel(data.x_label, labelpad=8, fontsize=11.5, fontproperties=font_prop)
    ax.set_ylabel(data.y_label, labelpad=15, fontsize=11.5, fontproperties=font_prop)
    ax.set_zlabel(
        "Outlier Severity (log₂ ratio)",
        labelpad=10,
        fontsize=11.5,
        fontproperties=font_prop,
    )
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
    ax.xaxis.set_major_locator(MaxNLocator(nbins=4, integer=True))
    ax.yaxis.set_major_locator(MaxNLocator(nbins=4, integer=True))
    ax.zaxis.set_major_locator(MaxNLocator(nbins=4, integer=True))
    _style_index_axes(ax)
    for axis in (ax.xaxis, ax.yaxis, ax.zaxis):
        if axis is ax.zaxis:
            formatter = ScalarFormatter(useMathText=False)
            formatter.set_powerlimits((-3, 4))
            axis.set_major_formatter(formatter)
        axis.pane.set_facecolor((0.985, 0.985, 0.985, 1.0))
        axis.pane.set_edgecolor((0.80, 0.80, 0.80, 1.0))
        axis._axinfo["grid"].update(
            {"color": (0.73, 0.73, 0.73, 0.55), "linewidth": 0.65}
        )
    ax.set_zlim(0.0, z_max)
    ax.tick_params(axis="both", which="major", pad=0, width=0.8, length=3)
    align_3d_axis_labels(ax)
    for tick in (*ax.get_xticklabels(), *ax.get_yticklabels(), *ax.get_zticklabels()):
        tick.set_fontproperties(font_prop)
        tick.set_fontsize(8.5)


def draw_relative_surface(
    ax: mpl.axes.Axes,
    data: SurfaceData,
    severity: np.ndarray,
    z_max: float,
    max_rows: int,
    max_cols: int,
    font_prop: font_manager.FontProperties,
    panel_title: str,
) -> tuple[int, int]:
    pooled, pooled_x, pooled_y = block_max_pool(
        severity,
        data.x,
        data.y,
        max_rows=max_rows,
        max_cols=max_cols,
    )
    grid_x, grid_y = np.meshgrid(pooled_x, pooled_y)
    ax.plot_surface(
        grid_x,
        grid_y,
        pooled,
        cmap=data.cmap,
        norm=PowerNorm(gamma=0.38, vmin=0.0, vmax=z_max),
        rcount=pooled.shape[0],
        ccount=pooled.shape[1],
        linewidth=0,
        antialiased=False,
        shade=False,
        rasterized=True,
    )
    ax.set_xlim(float(data.x.min()), float(data.x.max()))
    ax.set_ylim(float(data.y.min()), float(data.y.max()))
    style_relative_axis(ax, data, panel_title, z_max, font_prop)
    return pooled.shape


def render_relative_outlier_layers(
    layers: list[dict[str, Any]],
    output_dir: Path,
    font_prop: font_manager.FontProperties,
    max_rows: int,
    max_cols: int,
    png_dpi: int,
) -> list[dict[str, Any]]:
    prepared: list[dict[str, Any]] = []
    for layer in layers:
        weight = _surface_from_layer(layer, "weight")
        activation = _surface_from_layer(layer, "activation")
        weight_p99 = float(layer["weight_tensor_statistics"]["p99_abs"])
        activation_p99 = float(layer["activation_tensor_statistics"]["p99_abs"])
        weight_severity, weight_maximum = relative_outlier_severity(
            weight.values,
            weight_p99,
        )
        activation_severity, activation_maximum = relative_outlier_severity(
            activation.values,
            activation_p99,
        )
        prepared.append(
            {
                "layer_index": int(layer["layer_index"]),
                "weight": weight,
                "activation": activation,
                "weight_severity": weight_severity,
                "activation_severity": activation_severity,
                "weight_p99": weight_p99,
                "activation_p99": activation_p99,
                "weight_maximum": weight_maximum,
                "activation_maximum": activation_maximum,
            }
        )

    observed_max = max(
        max(item["weight_maximum"], item["activation_maximum"]) for item in prepared
    )
    common_z_max = float(max(1, int(np.ceil(observed_max))))
    results: list[dict[str, Any]] = []
    for item in prepared:
        figure = plt.figure(figsize=(13.2, 5.05), constrained_layout=False)
        weight_ax = figure.add_subplot(1, 2, 1, projection="3d")
        activation_ax = figure.add_subplot(1, 2, 2, projection="3d")
        weight_shape = draw_relative_surface(
            weight_ax,
            item["weight"],
            item["weight_severity"],
            common_z_max,
            max_rows,
            max_cols,
            font_prop,
            f"(a)  Layer {item['layer_index']} · Weight",
        )
        activation_shape = draw_relative_surface(
            activation_ax,
            item["activation"],
            item["activation_severity"],
            common_z_max,
            max_rows,
            max_cols,
            font_prop,
            f"(b)  Layer {item['layer_index']} · Activation",
        )
        figure.subplots_adjust(
            left=0.012,
            right=0.992,
            bottom=0.035,
            top=0.995,
            wspace=-0.02,
        )

        stem = f"llama2_7b_fp16_layer{item['layer_index']:02d}_relative_outlier"
        png_path = output_dir / f"{stem}.png"
        pdf_path = output_dir / f"{stem}.pdf"
        figure.savefig(png_path, dpi=png_dpi)
        figure.savefig(pdf_path, dpi=png_dpi)
        plt.close(figure)

        results.append(
            {
                "layer_index": item["layer_index"],
                "normalization_scope": "per_layer_per_kind_complete_tensor_p99",
                "weight_p99": item["weight_p99"],
                "activation_p99": item["activation_p99"],
                "weight_max_bits_above_p99": item["weight_maximum"],
                "activation_max_bits_above_p99": item["activation_maximum"],
                "common_z_axis": [0.0, common_z_max],
                "weight_display_shape": list(weight_shape),
                "activation_display_shape": list(activation_shape),
                "png": str(png_path),
                "pdf": str(pdf_path),
            }
        )

    return results


def render_layer(
    payload: dict[str, Any],
    layer: dict[str, Any],
    output_dir: Path,
    font_prop: font_manager.FontProperties,
    max_rows: int,
    max_cols: int,
    png_dpi: int,
) -> dict[str, Any]:
    layer_index = int(layer["layer_index"])
    weight = _surface_from_layer(layer, "weight")
    activation = _surface_from_layer(layer, "activation")

    figure = plt.figure(figsize=(13.2, 5.05), constrained_layout=False)
    weight_ax = figure.add_subplot(1, 2, 1, projection="3d")
    activation_ax = figure.add_subplot(1, 2, 2, projection="3d")

    weight_shape, weight_stats = draw_surface(
        weight_ax, weight, max_rows, max_cols, font_prop
    )
    activation_shape, activation_stats = draw_surface(
        activation_ax, activation, max_rows, max_cols, font_prop
    )
    style_3d_axis(weight_ax, weight, "(a)", font_prop)
    style_3d_axis(activation_ax, activation, "(b)", font_prop)
    weight_ax.set_zlim(0.0, 4.0)
    weight_ax.set_zticks([0.0, 1.0, 2.0, 3.0, 4.0])

    figure.subplots_adjust(left=0.012, right=0.992, bottom=0.035, top=0.995, wspace=-0.02)

    stem = f"llama2_7b_fp16_layer{layer_index:02d}_distribution"
    png_path = output_dir / f"{stem}.png"
    pdf_path = output_dir / f"{stem}.pdf"
    figure.savefig(png_path, dpi=png_dpi)
    figure.savefig(pdf_path, dpi=png_dpi)
    plt.close(figure)

    return {
        "layer_index": layer_index,
        "layer_name": layer["layer_name"],
        "weight_display_shape": list(weight_shape),
        "activation_display_shape": list(activation_shape),
        "weight_statistics": weight_stats,
        "weight_z_axis": [0.0, 4.0],
        "weight_z_ticks": [0.0, 1.0, 2.0, 3.0, 4.0],
        "activation_statistics": activation_stats,
        "png": str(png_path),
        "pdf": str(pdf_path),
    }


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
        available = [int(layer["layer_index"]) for layer in payload["layers"]]
        raise ValueError(f"No selected layer was found. Available layers: {available}")
    if selected is not None:
        found = {int(layer["layer_index"]) for layer in layers}
        missing = selected.difference(found)
        if missing:
            raise ValueError(f"Requested layers are not stored in the JSON: {sorted(missing)}")

    manifest = {
        "source_json": str(args.input.resolve()),
        "model": payload["model"],
        "model_revision": payload.get("model_revision"),
        "font": str(args.font.resolve()),
        "font_weight": 700,
        "png_dpi": args.png_dpi,
        "pooling": "block_max_for_rendering_only",
        "color_mapping": {
            "normalization": "PowerNorm",
            "gamma": 0.38,
            "weight_palette": ["#E6F0F8", "#8FBBDD", "#347FB5", "#06365D"],
            "activation_palette": ["#FCE7EA", "#ED929F", "#C7374F", "#6D0018"],
        },
        "requested_max_rows": args.max_rows,
        "requested_max_cols": args.max_cols,
        "relative_outlier_definition": "max(0, log2(abs(value) / complete_tensor_p99))",
        "normalization_scope": "per_layer_per_kind_complete_tensor_p99",
        "z_axis_label": "Outlier Severity (log₂ ratio)",
        "relative_outlier_figures": [],
    }

    relative_results = render_relative_outlier_layers(
        layers=layers,
        output_dir=args.output_dir.resolve(),
        font_prop=font_prop,
        max_rows=args.max_rows,
        max_cols=args.max_cols,
        png_dpi=args.png_dpi,
    )
    manifest["relative_outlier_figures"] = relative_results
    for result in relative_results:
        print(f"Rendered relative outlier layer {result['layer_index']}: {result['png']}")

    if args.include_absolute:
        manifest["absolute_magnitude_figures"] = []
        for layer in layers:
            result = render_layer(
                payload=payload,
                layer=layer,
                output_dir=args.output_dir.resolve(),
                font_prop=font_prop,
                max_rows=args.max_rows,
                max_cols=args.max_cols,
                png_dpi=args.png_dpi,
            )
            manifest["absolute_magnitude_figures"].append(result)
            print(f"Rendered optional absolute layer {result['layer_index']}: {result['png']}")

    manifest_path = args.output_dir.resolve() / "figure_manifest.json"
    with manifest_path.open("w", encoding="utf-8") as handle:
        json.dump(manifest, handle, ensure_ascii=False, indent=2)
        handle.write("\n")
    print(f"Wrote manifest: {manifest_path}")


if __name__ == "__main__":
    main()
