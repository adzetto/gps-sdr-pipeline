#!/usr/bin/env python3
"""Convert real 8-bit spoofing dataset into IQ uint8 baseband."""
from __future__ import annotations

import argparse
import json
import math
import os
from dataclasses import dataclass
from fractions import Fraction
from pathlib import Path
from typing import Iterator, Tuple

import numpy as np
import yaml
from scipy import signal
from tqdm import tqdm


def load_config(path: Path) -> dict:
    with path.open("r", encoding="utf-8") as fh:
        return yaml.safe_load(fh)


def chunk_reader(handle, chunk_samples: int, dtype: np.dtype) -> Iterator[np.ndarray]:
    while True:
        data = np.fromfile(handle, dtype=dtype, count=chunk_samples)
        if data.size == 0:
            break
        yield data


@dataclass
class ConverterConfig:
    input_path: Path
    output_path: Path
    interim_path: Path
    center_freq_hz: float
    target_center_hz: float
    fs_in: float
    fs_out: float
    quantization: str
    iq_gain: str | float
    chunk_size_bytes: int
    plots_dir: Path
    logs_dir: Path
    histogram_samples: int
    enable_histograms: bool
    use_hilbert: bool = True
    input_dtype: np.dtype = np.dtype("uint8")

    @classmethod
    def from_dict(cls, data: dict, root: Path) -> "ConverterConfig":
        sig = data["signal"]
        runtime = data.get("runtime", {})
        dtype_name = sig.get("dtype", "uint8")
        try:
            input_dtype = np.dtype(dtype_name)
        except TypeError as exc:  # pragma: no cover - configuration error
            raise ValueError(
                f"Unsupported dtype '{dtype_name}' in pipeline config"
            ) from exc
        return cls(
            input_path=(root / sig["input_path"]).resolve(),
            output_path=(root / sig["output_path"]).resolve(),
            interim_path=(
                root / sig.get("interim_path", "data/interim/iq.tmp")
            ).resolve(),
            center_freq_hz=float(sig["center_freq_hz"]),
            target_center_hz=float(sig["target_center_hz"]),
            fs_in=float(sig["fs_in"]),
            fs_out=float(sig["fs_out"]),
            quantization=sig.get("quantization", "u8"),
            iq_gain=sig.get("iq_gain", "auto"),
            chunk_size_bytes=int(sig.get("chunk_size", 64 * 1024 * 1024)),
            plots_dir=(root / runtime.get("plots_dir", "plots")).resolve(),
            logs_dir=(root / runtime.get("logs_dir", "logs")).resolve(),
            histogram_samples=int(runtime.get("histogram_samples", 2_000_000)),
            enable_histograms=bool(runtime.get("enable_histograms", True)),
            use_hilbert=bool(sig.get("use_hilbert", True)),
            input_dtype=input_dtype,
        )


class DatConverter:
    def __init__(self, cfg: ConverterConfig):
        self.cfg = cfg
        self.cfg.output_path.parent.mkdir(parents=True, exist_ok=True)
        self.cfg.interim_path.parent.mkdir(parents=True, exist_ok=True)
        self.cfg.plots_dir.mkdir(parents=True, exist_ok=True)
        self.cfg.logs_dir.mkdir(parents=True, exist_ok=True)
        self.log_file = self.cfg.logs_dir / "convert.log"
        self.phase = 0.0
        self.max_complex = 1e-9
        self.total_input_samples = 0
        self.total_output_samples = 0
        self.chunk_items = max(
            1, self.cfg.chunk_size_bytes // self.cfg.input_dtype.itemsize
        )
        frac = Fraction(int(self.cfg.fs_out), int(self.cfg.fs_in)).limit_denominator(
            max_denominator=8192
        )
        self.up = frac.numerator
        self.down = frac.denominator
        # Rotate spectrum so that the target center ends up at baseband.
        self.phase_step = (
            2.0
            * math.pi
            * (self.cfg.target_center_hz - self.cfg.center_freq_hz)
            / self.cfg.fs_in
        )

    def log(self, message: str) -> None:
        stamp = np.datetime64("now").astype("datetime64[ms]").astype(str)
        line = f"[{stamp}] [convert] {message}"
        print(line)
        with self.log_file.open("a", encoding="utf-8") as fh:
            fh.write(line + "\n")

    def run(self) -> None:
        self._ensure_input_path()
        self.log(
            f"Starting conversion: {self.cfg.input_path} -> {self.cfg.output_path}"
        )
        with self.cfg.input_path.open("rb") as handle, self.cfg.interim_path.open(
            "wb"
        ) as interim:
            for raw in tqdm(
                chunk_reader(handle, self.chunk_items, self.cfg.input_dtype),
                desc="Mix & resample",
                unit="chunk",
            ):
                self.total_input_samples += raw.size
                complex_block = self._process_chunk(raw)
                if complex_block.size == 0:
                    continue
                complex_block.astype(np.complex64).tofile(interim)
        self._quantize()
        self._write_metadata()

    def _process_chunk(self, raw: np.ndarray) -> np.ndarray:
        real = self._normalize_real(raw)
        analytic: np.ndarray
        if self.cfg.use_hilbert:
            analytic = signal.hilbert(real)
        else:
            analytic = real.astype(np.complex64)
        phases = self.phase + self.phase_step * np.arange(real.size, dtype=np.float64)
        oscillators = np.exp(-1j * phases)
        mixed = analytic * oscillators.astype(np.complex64)
        self.phase = phases[-1] + self.phase_step
        resampled = signal.resample_poly(
            mixed, self.up, self.down, axis=0, padtype="line"
        )
        if resampled.size == 0:
            return resampled
        self.max_complex = max(self.max_complex, float(np.max(np.abs(resampled))))
        self.total_output_samples += resampled.size
        return resampled

    def _quantize(self) -> None:
        if self.total_output_samples == 0:
            self.cfg.output_path.touch()
            return
        if self.cfg.iq_gain == "auto":
            scale = self.max_complex * 1.05
        else:
            scale = float(self.cfg.iq_gain)
        scale = max(scale, 1e-6)
        dtype = np.complex64
        total_complex = self.total_output_samples
        block = max(1, self.cfg.chunk_size_bytes // 8)
        out_path = self.cfg.output_path
        interim_path = self.cfg.interim_path
        if out_path.exists():
            out_path.unlink()
        mmap = np.memmap(interim_path, dtype=dtype, mode="r", shape=(total_complex,))
        with out_path.open("ab") as out:
            for start in tqdm(
                range(0, total_complex, block), desc="Quantize", unit="blk"
            ):
                stop = min(start + block, total_complex)
                segment = np.array(mmap[start:stop])
                iq = np.clip(segment / scale, -1.0, 1.0)
                interleaved = self._to_interleaved(iq)
                interleaved.tofile(out)
        del mmap
        try:
            interim_path.unlink()
        except OSError:
            pass

    def _ensure_input_path(self) -> None:
        if self.cfg.input_path.exists():
            return
        stem = self.cfg.input_path.stem
        suffix = self.cfg.input_path.suffix
        pattern = f"{stem}-*{suffix}"
        fallback = sorted(self.cfg.input_path.parent.glob(pattern))
        for candidate in fallback:
            if candidate.is_file():
                resolved = candidate.resolve()
                self.log(
                    f"Configured input {self.cfg.input_path} missing; falling back to {resolved}"
                )
                self.cfg.input_path = resolved
                return
        raise FileNotFoundError(f"Input file not found: {self.cfg.input_path}")

    def _normalize_real(self, raw: np.ndarray) -> np.ndarray:
        if self.cfg.input_dtype == np.dtype("uint8"):
            return (raw.astype(np.float32) - 128.0) / 128.0
        if self.cfg.input_dtype == np.dtype("int8"):
            return raw.astype(np.float32) / 128.0
        raise ValueError(f"Unsupported input dtype {self.cfg.input_dtype}")

    def _to_interleaved(self, iq: np.ndarray) -> np.ndarray:
        if self.cfg.quantization.lower() == "u8":
            i = np.round((iq.real + 1.0) * 127.5).astype(np.int16)
            q = np.round((iq.imag + 1.0) * 127.5).astype(np.int16)
            i = np.clip(i, 0, 255).astype(np.uint8)
            q = np.clip(q, 0, 255).astype(np.uint8)
        else:
            i = np.round(iq.real * 127.0).astype(np.int16)
            q = np.round(iq.imag * 127.0).astype(np.int16)
            i = np.clip(i, -128, 127).astype(np.int8)
            q = np.clip(q, -128, 127).astype(np.int8)
        interleaved = np.empty(i.size * 2, dtype=i.dtype)
        interleaved[0::2] = i
        interleaved[1::2] = q
        return interleaved

    def _write_metadata(self) -> None:
        meta = {
            "input_path": str(self.cfg.input_path),
            "output_path": str(self.cfg.output_path),
            "input_dtype": str(self.cfg.input_dtype),
            "center_freq_hz": self.cfg.center_freq_hz,
            "target_center_hz": self.cfg.target_center_hz,
            "fs_in": self.cfg.fs_in,
            "fs_out": self.cfg.fs_out,
            "samples_in": self.total_input_samples,
            "samples_out": self.total_output_samples,
            "max_complex": self.max_complex,
            "quantization": self.cfg.quantization,
            "chunk_size_bytes": self.cfg.chunk_size_bytes,
        }
        meta_path = self.cfg.output_path.with_suffix(
            self.cfg.output_path.suffix + ".json"
        )
        with meta_path.open("w", encoding="utf-8") as fh:
            json.dump(meta, fh, indent=2)
        self.log(f"Wrote metadata to {meta_path}")
        self.log(
            f"Completed conversion. Samples in {self.total_input_samples}, out {self.total_output_samples}"
        )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Convert real 8-bit DAT to IQ BIN")
    parser.add_argument(
        "--config", default="configs/pipeline.yaml", help="Path to pipeline YAML config"
    )
    parser.add_argument(
        "--root",
        default=Path(__file__).resolve().parents[1],
        type=Path,
        help="Workspace root",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    root = args.root if isinstance(args.root, Path) else Path(args.root)
    cfg = ConverterConfig.from_dict(load_config(Path(args.config)), root)
    converter = DatConverter(cfg)
    converter.run()


if __name__ == "__main__":
    main()
