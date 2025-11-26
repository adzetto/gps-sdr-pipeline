#!/usr/bin/env python3
"""Generate quick statistics and histogram for raw dataset."""
from __future__ import annotations

import argparse
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Quick probe of binary samples")
    parser.add_argument("input", help="Path to raw .dat/.bin file")
    parser.add_argument("--samples", type=int, default=2_000_000, help="Number of samples to read")
    parser.add_argument("--output", default="plots/quick_probe.png", help="Histogram output path")
    parser.add_argument("--dtype", default="uint8", help="Input sample dtype (uint8 or int8)")
    parser.add_argument("--fft-output", default="plots/quick_probe_fft.png", help="FFT plot output path")
    parser.add_argument("--fft-size", type=int, default=131072, help="Number of samples for FFT window")
    parser.add_argument("--fs", type=float, default=None, help="Sample rate in Hz (for FFT axis)")
    parser.add_argument("--no-fft", action="store_true", help="Disable FFT visualization")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    path = Path(args.input)
    if not path.exists():
        raise FileNotFoundError(path)
    count = args.samples
    dtype = np.dtype(args.dtype)
    with path.open("rb") as fh:
        raw = np.fromfile(fh, dtype=dtype, count=count)
    if raw.size == 0:
        raise RuntimeError("No data read from file")
    if dtype == np.dtype("uint8"):
        centered = (raw.astype(np.float32) - 128.0) / 128.0
    elif dtype == np.dtype("int8"):
        centered = raw.astype(np.float32) / 128.0
    else:
        raise ValueError(f"Unsupported dtype {dtype}")
    stats = {
        "min": float(centered.min()),
        "max": float(centered.max()),
        "mean": float(centered.mean()),
        "std": float(centered.std()),
        "samples": int(centered.size),
    }
    print("Quick probe stats:")
    for key, value in stats.items():
        print(f"  {key}: {value}")
    fig, ax = plt.subplots(figsize=(6, 4))
    ax.hist(centered, bins=256, color="steelblue", alpha=0.8)
    ax.set_title("Amplitude histogram (normalized)")
    ax.set_xlabel("Amplitude")
    ax.set_ylabel("Count")
    fig.tight_layout()
    out_path = Path(args.output)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(out_path)
    print(f"Histogram saved to {out_path}")
    if not args.no_fft:
        fft_samples = min(args.fft_size, centered.size)
        if fft_samples < 16:
            raise RuntimeError("Not enough samples for FFT")
        window = np.hanning(fft_samples)
        spectrum = np.fft.rfft(centered[:fft_samples] * window)
        magnitude = 20.0 * np.log10(np.abs(spectrum) + 1e-12)
        if args.fs:
            freqs = np.fft.rfftfreq(fft_samples, d=1.0 / args.fs) / 1e6
            xlabel = "Frequency (MHz)"
        else:
            freqs = np.fft.rfftfreq(fft_samples, d=1.0)
            xlabel = "Normalized frequency (cycles/sample)"
        fig_fft, ax_fft = plt.subplots(figsize=(8, 4))
        ax_fft.plot(freqs, magnitude, color="darkorange", linewidth=1.0)
        ax_fft.set_title(f"FFT magnitude ({fft_samples} samples)")
        ax_fft.set_xlabel(xlabel)
        ax_fft.set_ylabel("Magnitude (dB)")
        ax_fft.grid(True, alpha=0.3)
        fig_fft.tight_layout()
        fft_path = Path(args.fft_output)
        fft_path.parent.mkdir(parents=True, exist_ok=True)
        fig_fft.savefig(fft_path)
        print(f"FFT plot saved to {fft_path}")


if __name__ == "__main__":
    main()
