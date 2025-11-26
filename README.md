# GPS SDR DSP Pipeline

<div align="center">
  <img src="logo/logo.svg" alt="GPS SDR Pipeline Logo" width="480">
</div>

This document serves as a technical article for the offline GPS spoofing-to-IQ pipeline. It highlights the mathematical signal processing steps, reproducible commands, and verification hooks that bridge raw captures to `annappo/GPS-SDR-Receiver`.

**Signal integrity goals.** The pipeline is constrained by three classical DSP design targets:

- **Spectral confinement:** after mixing, energy outside $[-F_s^{\text{out}}/2,\, F_s^{\text{out}}/2]$ is suppressed by the polyphase prototype with $\ge 60$ dB stopband.
- **Quantization fidelity:** uniform scalar quantization with step $\Delta \approx 1/127.5$ yields peak SNR $\approx 6.02N + 1.76$ dB for $N=8$ bits, assuming full-scale drive; auto gain keeps the signal within this regime.
- **Phase coherence:** continuous NCO phasing across chunks preserves $\phi_{n+1} = \phi_n + \omega_0 N_{\text{chunk}}$ (with $\omega_0 = 2\pi \Delta f / F_s^{\text{in}}$), eliminating inter-chunk discontinuities that would otherwise manifest as spectral stitching.

**Symbol table.**

| Symbol | Meaning |
| :--- | :--- |
| $x[n]$ | Raw ADC real-valued samples (8-bit) |
| $s[n]$ | Normalized real stream $x[n]/128$ |
| $a[n]$ | Analytic signal $s[n] + j\,\hat{s}[n]$ |
| $f_c,\; f_t$ | Capture center and GPS L1 target centers |
| $\Delta f$ | Frequency shift $f_t - f_c$ |
| $F_s^{\text{in}},\; F_s^{\text{out}}$ | Input and output sample rates |
| $r = p/q$ | Reduced resampling ratio $F_s^{\text{out}}/F_s^{\text{in}}$ |
| $h[m]$ | Polyphase low-pass prototype taps |
| $z[k]$ | Post-resample complex envelope |
| $g$ | IQ full-scale gain (auto or fixed) |
| $\Delta$ | Quantizer step $\approx 1/127.5$ after scaling |
| $\omega_0$ | NCO radian step $2\pi \Delta f / F_s^{\text{in}}$ |
| $\phi_n$ | NCO phase accumulator at sample $n$ |

---

## 1. Signals, Notation, and Data Model

Let

- $x[n] \in \mathbb{Z}_{8}$ be the **real-valued** ADC output sampled at $F_s^{\text{in}} = 26\,\text{MS/s}$.
- $s[n] = x[n] / 128$ be the normalized baseband in $[-1, 1)$.
- $f_c = 1{,}569.03\,\text{MHz}$ (capture center) and $f_t = 1{,}575.42\,\text{MHz}$ (GPS L1).
- $\Delta f = f_t - f_c$ and $F_s^{\text{out}} \in \{2.048\,\text{MS/s},\; 4.096\,\text{MS/s}\}$.

**Analytic extension.** The Hilbert transform $\mathcal{H}\{\cdot\}$ produces $a[n] = s[n] + j\,\hat{s}[n]$, suppressing negative frequencies so that a single-sided spectrum can be rotated cleanly.

**Numerically controlled oscillator (NCO).**
$u[n] = e^{-j 2\pi \Delta f n / F_s^{\text{in}}}, \qquad y[n] = a[n]\,u[n].$
This shifts the spectral peak from $f_c$ to $f_t$, sending GPS L1 content to baseband.

**Polyphase resampling.** Let the rate ratio be
$r = \frac{F_s^{\text{out}}}{F_s^{\text{in}}} = \frac{p}{q} \quad \text{(reduced by gcd)}.$
`resample_poly` realizes a finite-impulse-response low-pass $h[m]$ with at least 60 dB stopband, applied as
$z[k] = \sum_{m} h[m]\; y[kq - m], \qquad k \in \mathbb{Z}.$

**Quantization to interleaved IQ (u8).**
$q_I = \text{clip}\big((\Re\{z\}/g + 1)\cdot 127.5,\; 0,\; 255\big), \qquad
q_Q = \text{clip}\big((\Im\{z\}/g + 1)\cdot 127.5,\; 0,\; 255\big).$
The gain $g$ sets the full-scale reference: auto mode picks $g \approx 1.05 \max_k |z[k]|$ (headroom against peaks), while a fixed $g$ enforces deterministic scaling across runs. Geometrically, this projects $z$ onto the cube $[-g, g]^2$, translates to $[0,255]^2$, and rounds to the nearest lattice point, producing uniform quantization noise with step size $\Delta \approx 1/127.5$ of the normalized amplitude.

> [!NOTE]
> If `use_hilbert: false`, the pipeline skips analytic construction and treats the input as $I$-only, which alters image rejection and spectral symmetry assumptions.
> 
> Without an analytic extension, the spectrum is conjugate-symmetric and any frequency shift by $\Delta f$ produces mirror terms at $\pm \Delta f$. Expect image leakage unless the downstream receiver explicitly suppresses the mirrored band.
>
> [!TIP]
> Keep `use_hilbert: true` for real-valued captures so that the NCO shift acts on a single-sided spectrum; this preserves the textbook modulation property $X(f - \Delta f)$ and prevents negative-frequency folding when decimating.

---

## 2. Pipeline Overview (Commands)

| Stage | Command (Linux/macOS) | PowerShell equivalent |
| :--- | :--- | :--- |
| Init venv | `make init` | `make init` |
| Fetch data | `make fetch` | `make fetch` |
| Probe raw | `make probe` | `make probe` |
| Convert (2.048 MS/s) | `make convert` | `make convert` |
| Convert (4.096 MS/s) | `make convert-4m` | `make convert-4m` |
| Run receiver (Fairdata IQ) | `make run` | `make run` |
| Run receiver (sample IQ) | `make run-sample` | `make run-sample` |

Key paths
- Raw input: `data/raw/TGS_L1_E1.dat` (auto-fallback to `TGS_L1_E1-*.dat`)
- Processed IQ: `data/processed/TGS_L1_E1_2p048Msps_iq_u8.bin`
- Interim complex64: `data/interim/TGS_L1_E1_complex64.tmp`
- Configs: `configs/pipeline.yaml`, `configs/pipeline_4Msps.yaml`
- Logs: `logs/convert.log`, `logs/run.log`, `logs/run_sample.log`

---

## 3. Mathematical Deep Dive

<details>
<summary>DSP derivation (click to expand)</summary>

1. **Normalization**  
   $s[n] = (x[n] - b)/128$, where $b = 128$ for `uint8`, $0$ for `int8`. This removes DC bias from unsigned captures and scales the lattice to a unitless, symmetric range.

2. **Analytic Signal (Hilbert)**  
   $a[n] = s[n] + j\,\hat{s}[n]$ with $\hat{s}[n]$ the Hilbert transform. The quadrature pair forms a $90^{\circ}$ phase-shifted replica that zeros negative frequencies, yielding a textbook analytic signal suitable for single-sideband mixing and spectral translations.

3. **Frequency Translation**  
   Multiply by $u[n] = e^{-j 2\pi \Delta f n / F_s^{\text{in}}}$ to rotate the spectrum by $\Delta f$, sending $f_t$ to baseband while preserving phase continuity chunk to chunk. This uses the discrete-time modulation property: a complex exponential multiplier shifts the spectrum without altering magnitude.

4. **Decimation via Polyphase Resampling**  
   `resample_poly(y, up, down)` implements
   $$
   z[k] = \sum_m h[m]\; y[k \cdot \tfrac{down}{up} - m],
   $$
   where $h[m]$ is the anti-alias/anti-imaging prototype. Reducing `up/down` by gcd limits integer growth and stabilizes the effective $\ell_1$ norm of $h$. The passband retains content below $F_s^{\text{out}}/2$, and the Kaiser windowed prototype keeps sidelobes beneath the 60 dB design target, ensuring textbook bandlimiting before decimation.

5. **Gain and Quantization**  
   Let $g = 1.05 \cdot \max_k |z[k]|$ for auto gain. The u8 mapper uses affine scaling to $[0,255]$; i8 would use symmetric clipping to $[-128, 127]$ after scaling by 127. This introduces quantization noise with a peak SNR of roughly $6.02N + 1.76$ dB for $N=8$, assuming full-scale excitation and uniform quantizer steps.

6. **Metadata**  
   Stored in `*.bin.json`: sample counts, $\Delta f$, $F_s^{\text{in}}$, $F_s^{\text{out}}$, quantization mode, chunk size, and observed max magnitude.

</details>

> [!TIP]
> For spectral fidelity, increase `chunk_size` to reduce Hilbert edge effects and ensure the resampler’s transition band stays narrow relative to the downsampled Nyquist zone.

---

## 3.1 Notebook-Derived Analyses (Spectrogram and PSD)

The companion notebooks implement an STFT-based spectrogram with Doppler overlays:

- **STFT grid:** $Z_{f,t} = \text{STFT}\{x\}(f,t)$ computed with $N_{\text{seg}}$-point windows and overlap $N_{\text{ovl}}$, producing
  $$
  P_{f,t} = 20 \log_{10} \big( |Z_{f,t}| + \epsilon \big)
  $$
  for numerical floor $\epsilon$.
- **Frequency shift for plotting:** $f$-bins are fftshifted to $[-F_s/2,\, F_s/2]$ so Doppler lines appear centered at 0 Hz after downconversion.
- **Doppler overlays:** For each acquired PRN with Doppler $\nu_{\text{doppler}}$, the notebook draws $f = \nu_{\text{doppler}}$ horizontal guides on the STFT heatmap to visually align correlation peaks with spectral energy.
- **Welch PSD (iq_comparison):** Using segment length $L$ and overlap $\alpha L$, the PSD estimator averages periodograms to reduce variance, reporting
  $$
  S_{xx}(f) = \frac{1}{K} \sum_{k=1}^{K} \frac{1}{L} \left| \sum_{n=0}^{L-1} w[n]\, x_k[n]\, e^{-j 2\pi f n / F_s} \right|^2,
  $$
  where $w[n]$ is the window and $K$ the number of segments.
- **Histogram/constellation diagnostics:** The notebook compares empirical amplitude CDFs, IQ histograms, and constellations across captures to detect gain/linearity issues or DC offset.

These analyses mirror the runtime DSP: they assume the same $F_s^{\text{out}}$ and normalization used in `scripts/convert_dat_to_bin.py`, ensuring that visual diagnostics are aligned with the processed IQ scale.

---

## 4. Practical Workflows

**Fetch (resumable + checksums)**
```bash
export FAIRDATA_DIRECT_URL="https://signed/fairdata/link/TGS_L1_E1.dat"
export HIDRIVE_FILE_URL="https://signed/hidrive/link/230914_data_90s.bin"
make fetch
```

**Probe the first 2M samples**
```bash
make probe RAW_DTYPE=int8
# or direct:
env/.venv/bin/python scripts/quick_probe.py data/raw/TGS_L1_E1.dat --samples 2000000 --dtype int8 --fs 26000000
```

**Convert with default profile**
```bash
make convert
# explicit:
env/.venv/bin/python scripts/convert_dat_to_bin.py --config configs/pipeline.yaml --root .
```

**Convert at 4.096 MS/s**
```bash
make convert-4m
```

**Run receiver offline**
```bash
make run            # uses processed Fairdata IQ
make run-sample     # uses external/GPS-SDR-Receiver/data/test.bin
```

---

## 5. Validation and Quality Checks

- `scripts/validate_run.py --log logs/run.log --min-prn 1 --require-task-finish`  
  Parses PRN correlation lines, Doppler estimates, subframe/ephemeris hits, and Task1/Task2 completion. Exits non-zero on failure.
- `plots/quick_probe.png`, `plots/quick_probe_fft.png`  
  Amplitude histogram + FFT magnitude for early sanity checks.
- Metadata inspection: `cat data/processed/TGS_L1_E1_2p048Msps_iq_u8.bin.json`

---

## 6. Configuration Anatomy

```yaml
signal:
  input_path: data/raw/TGS_L1_E1.dat
  output_path: data/processed/TGS_L1_E1_2p048Msps_iq_u8.bin
  center_freq_hz: 1569030000      # f_c
  target_center_hz: 1575420000    # f_t
  fs_in: 26000000                 # F_s^in
  fs_out: 2048000                 # F_s^out
  quantization: u8                # or i8
  iq_gain: auto                   # or fixed scalar
  chunk_size: 67108864            # bytes
  dtype: int8                     # raw ADC format
runtime:
  enable_histograms: true
  histogram_samples: 2097152
```

**Common tweaks**
- Increase `fs_out` (use `pipeline_4Msps.yaml`) to widen the receiver’s processed bandwidth.
- Disable `use_hilbert` to test pure quadrature mixing (less image rejection, no negative-frequency suppression).
- Set `iq_gain` to a fixed value to maintain deterministic amplitude scaling across runs.

---

## 7. Extended Topics

- **Reverse conversion (loss-aware)**  
  A true inverse is impossible (bandwidth reduction + quantization), but a principled approximation would upsample complex IQ back to 26 MS/s, mix by $-\Delta f$, and, if required, collapse to real int8 with dithering to minimize bias.
- **Window and filter design**  
  `resample_poly` defaults to a Kaiser windowed low-pass. For sharper skirts, use a custom `window=("kaiser", beta)`; for lower latency, reduce `chunk_size` but expect more edge ripple.
- **Phase continuity**  
  The converter maintains an NCO phase accumulator across chunks: $\phi_{n+1} = \phi_n + \omega_0\, N_{\text{chunk}}$, where $\omega_0 = 2\pi \Delta f / F_s^{\text{in}}$. This enforces continuity of $u[n] = e^{-j\phi_n}$ at chunk boundaries, preventing spectral stitching artifacts when concatenating outputs.
- **Numerical stability**  
  All heavy math runs in `float32`/`complex64`, but conversion to `Fraction` for rate reduction guards against large integer accumulators and ensures bounded round-off in `up/down`.

---

## 8. Roadmap / TODO

- [ ] Loss-aware inverse toolchain: complex upsample + back-rotation + optional real quantization with global peak scaling and dithering.
- [ ] Dual-rate conversion cache: reuse Hilbert/interim buffers to emit both 2.048 MS/s and 4.096 MS/s in one pass.
- [ ] JSON spectral fingerprints from `quick_probe.py` for CI drift detection of amplitude and PSD.
- [ ] Inline ephemeris/subframe annotations inside `logs/run_*.log` with structured JSON sidecars.
- [ ] Optional `use_hilbert: false` profile with image-rejection metrics reported post-conversion.

---

## 9. References and Footnotes

- GPS-SDR-Receiver upstream: [`external/GPS-SDR-Receiver`](external/GPS-SDR-Receiver)
- FFT sizing: default $N_{\text{FFT}} = 131{,}072$ for probes, adjustable via `--fft-size`.
- Disk budget: complex64 interim at 26 MS/s for long captures can reach tens of GB; ensure free space ≥ 20 GB before `make convert`.

[^adc]: Raw ADC dynamic range assumes 8-bit two’s complement; unsigned captures are recentred before normalization.
