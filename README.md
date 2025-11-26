# GPS SDR Workspace

This workspace automates fetching the spoofing dataset, converting it into the IQ baseband format expected by [`annappo/GPS-SDR-Receiver`](https://github.com/annappo/GPS-SDR-Receiver), and executing the receiver offline. All steps are scripted and exposed via `make` targets so the pipeline is reproducible on Linux/macOS (bash) and Windows (PowerShell).

## Directory Layout

```
external/                   # third-party repos (GPS-SDR-Receiver cloned here)
data/
  raw/                      # downloaded Fairdata or HiDrive payloads
  interim/                  # temporary complex64 buffers during conversion
  processed/                # final IQ binaries for the receiver
scripts/                    # automation entrypoints (bash + PowerShell)
configs/pipeline.yaml       # DSP + resampling parameters
env/.venv                   # Linux virtual environment created by `make init` (PowerShell uses env/.venv-win)
logs/                       # fetch / convert / run logs
plots/                      # quick-probe histograms
notebooks/sanity_check.ipynb# placeholder for exploratory analysis
```

## Prerequisites

- Python 3.11+
- `make`, `curl`, `git`
- ~20 GB free disk space for raw + processed data
- Direct download URLs for the datasets (Fairdata UI is JavaScript driven)

## Quick Start (Linux / macOS)

```bash
cd gps_sdr_workspace
make init                                  # create env/.venv (Linux) or env/.venv-win (Windows) and install deps
export FAIRDATA_DIRECT_URL="https://..."   # obtain signed link to TGS_L1_E1.dat
export HIDRIVE_FILE_URL="https://..."     # optional: signed HiDrive link
make fetch                                 # downloads into data/raw/
make convert                               # runs scripts/convert_dat_to_bin.py
make run-sample                            # optional: sanity-check repo's sample IQ
make run                                   # patches gpsglob.py and executes gpssdr.py
```

The default `make all` target runs `init → fetch → convert → run`. `make probe` launches `scripts/quick_probe.py` to inspect the first couple of megabytes and save a histogram to `plots/raw_hist.png`.

### Windows PowerShell

`make` now delegates to the PowerShell entrypoints under `scripts/windows/`, so `make init fetch probe convert run` works from PowerShell 7.5+ (including UNC paths such as `\\wsl.localhost\...`). Windows uses its own virtual environment at `env/.venv-win`, allowing the Linux `env/.venv` to coexist when you bounce between shells. The PowerShell wrappers mirror the bash flags, so you can also call them directly (e.g., `scripts/windows/run_receiver_offline.ps1 -Input ...`). Before running `make`, unlock the session execution policy:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

## Data Acquisition

`scripts/fetch_data.sh` (and its PowerShell counterpart) handle resumable downloads with `curl -L -C - --retry 5`. They rely on two optional environment variables:

- `FAIRDATA_DIRECT_URL` – direct HTTP link to `TGS_L1_E1.dat`. If unset, the script reminds you to provide it after authenticating via https://etsin.fairdata.fi/dataset/367379a8-7d78-4b08-91f0-8027ce7a621b/data.
- `HIDRIVE_FILE_URL` – signed URL for a `.bin` / `.dat` file from https://my.hidrive.com/share/ngox89fz9p#$/ (e.g., `230914_data_90s.bin`).
- `HIDRIVE_FILENAME` and `FAIRDATA_SHA256` are optional overrides for destination filename and checksum verification.
- `configs/checksums.txt` stores the canonical SHA-256 manifest. `scripts/fetch_data.sh` automatically verifies any file listed there (or in the path pointed to `CHECKSUM_MANIFEST`). Populate the manifest with the official hashes as soon as Fairdata publishes them.

All transfers log to `logs/fetch.log` and perform a free-space sanity check (~5 GB).

## Conversion Pipeline

`configs/pipeline.yaml` describes the DSP chain and metadata for the TGS capture. Make sure `signal.dtype` matches the incoming stream (`int8` for the Fairdata dump, `uint8` for unsigned ADC logs). The converter implements the following sequence per chunk:

1. Read raw samples and normalize to `float32` in [-1, 1): signed streams divide by 128, unsigned streams subtract 128 first.
2. Build the analytic signal with `scipy.signal.hilbert` (result: complex64).
3. Mix with a numerically controlled oscillator `exp(-j 2π Δf n / Fs_in)` to translate from 1,569.03 MHz to 1,575.42 MHz.
4. `scipy.signal.resample_poly` with rational `fs_out/fs_in` (auto-reduced) providing ≥60 dB stopband; the stream is kept in `complex64` and flushed to `data/interim/TGS_L1_E1_complex64.tmp`.
5. Auto-scale based on the global max magnitude, clamp to [-1, 1], and quantize to interleaved IQ. `u8` mode maps to `[0,255]` (`np.round((x+1)*127.5)`), while `i8` would map to `[-128,127]`.
6. Emit `data/processed/TGS_L1_E1_2p048Msps_iq_u8.bin` plus `*.json` metadata summarizing input/output sample counts, gain, center frequencies, and chunk size.

`scripts/convert_dat_to_bin.py` streams the raw file in 64 MiB chunks, tracks progress with `tqdm`, records histograms if enabled, and keeps RAM bounded via the on-disk complex64 buffer in `data/interim`. Adjust any parameter (sample rates, center frequencies, quantization, chunk size, Hilbert toggle) in `pipeline.yaml` and rerun `make convert`. If you want a higher-output sample rate, use the companion config `configs/pipeline_4Msps.yaml` (targeting 4.096 MS/s) via `make convert-4m`; the resulting IQ lands at `data/processed/TGS_L1_E1_4p096Msps_iq_u8.bin`.

### Quick Probe

`scripts/quick_probe.py data/raw/TGS_L1_E1.dat --samples 2000000 --dtype int8 --fs 26000000` reads the first two million signed samples, prints min/mean/max/std, saves a histogram, and now also emits an optional FFT/Spectrum plot (`--no-fft` to skip, `--fft-size`, `--fft-output` to customize). The FFT axis uses the provided `--fs` sampling rate when available, making it easy to confirm spectral shape alongside the amplitude histogram.

## Running GPS-SDR-Receiver Offline

`scripts/run_receiver_offline.sh` now accepts `--input`, `--log`, and `--python` so you can point the receiver to any IQ file, select a dedicated log target, or override the interpreter. By default it reads `data/processed/TGS_L1_E1_2p048Msps_iq_u8.bin` and writes `logs/run.log`. After `gpssdr.py` exits, the script automatically runs `scripts/validate_run.py` to parse the log, ensure a minimum number of PRNs were acquired, and confirm both `Task1/Task2 finished` markers. Customize thresholds via `RUN_MIN_PRN`, `RUN_REQUIRE_TASK_FINISH=0`, and—in the validator—`--min-subframes/--min-ephemeris` once the receiver starts printing navigation-frame or ephemeris logs. PowerShell wrapper mirrors these checks.

1. Ensures the requested IQ file exists and that `env/.venv` (Linux) or `env/.venv-win` (PowerShell) holds the dependencies.
2. Temporarily patches `external/GPS-SDR-Receiver/src/gpsglob.py` to set `LIVE_MEAS=False`, plug in the IQ filename, and point `REL_PATH` to the IQ directory (absolute path for reliability).
3. Executes `gpssdr.py` with the workspace virtualenv, teeing stdout/stderr into the chosen log.
4. Restores the original `gpsglob.py` afterward.

Use `make run-sample` to validate the upstream demo capture at `external/GPS-SDR-Receiver/data/test.bin` (log: `logs/run_sample.log`) before running `make run`, which targets the converted Fairdata capture.

Monitor `logs/run.log` for correlation peaks, PRN acquisition, and decoding of navigation subframes. If acquisition is weak, consider tweaking `fs_out` (e.g., double to 4.096 MS/s) or GPS-SDR-Receiver parameters such as `MAX_SAT`, `CORR_AVG`, or `SDR_FREQCORR` inside `gpsglob.py`.

## Known Limitations & Tips

- **Fairdata/HiDrive authentication**: both portals embed download tokens in their web apps. Obtain the direct URL manually (browser dev-tools → copy request) and export it as `FAIRDATA_DIRECT_URL`/`HIDRIVE_FILE_URL`.
- **Large files**: the conversion script may consume tens of GB of temporary disk space (complex64 intermediate). Ensure you have sufficient capacity before running `make convert`.
- **Hilbert transform**: streaming Hilbert on massive captures introduces slight edge artifacts per chunk. Increase `chunk_size` or disable Hilbert (`use_hilbert: false`) if you prefer a pure quadrature mixing approach.
- **Windows**: use the PowerShell scripts; adjust `env/.venv-win/Scripts/python.exe` if you relocate the workspace.
- **Cleanup**: `make clean` removes processed/interim outputs and logs but preserves raw downloads.
- **Alternate filenames**: Fairdata sometimes publishes the capture as `TGS_L1_E1-00X.dat`. The converter and `make probe` now auto-detect these variants, so you can drop the file into `data/raw/` without renaming.

## Notebook Stub

`notebooks/sanity_check.ipynb` is a placeholder. Drop in your exploratory EDA (e.g., plotting spectrograms) using the processed IQ data; the virtualenv (`env/.venv` on Linux, `env/.venv-win` on Windows) already includes `matplotlib` and `numpy`.

`notebooks/spectrogram.ipynb` is a ready-made utility that loads a processed IQ file, runs an STFT via `scipy.signal.stft`, renders the spectrogram in SVG (scienceplots styling), and overlays Doppler lines inferred from the latest `logs/run_*.log`. Configure `DATA_PATH`, `LOG_PATH`, and `FS_HZ` at the top of the notebook to pivot between datasets.

## Troubleshooting

| Symptom | Likely Cause / Fix |
| --- | --- |
| `FAIRDATA_DIRECT_URL not set` | Export the signed direct link before running `make fetch`. |
| `Processed IQ file not found` | Run `make convert` (and ensure conversion succeeded) before `make run`. |
| `gpssdr.py` exits immediately | Check `logs/run.log` for stack traces, ensure PyQt5 deps are installed (headless mode still requires X11 libs on Linux). |
| Weak acquisition / no PRNs | Try extending `MEAS_TIME`, raising `SAMPLE_RATE` (via conversion), or supplying a verified HiDrive `.bin`. |

## Next Steps

- Automatically enrich `logs/run_*.log` with explicit subframe/ephemeris markers by instrumenting `GPS-SDR-Receiver` (once upstream accepts the hooks).
- Orchestrate both 2.048 MS/s and 4.096 MS/s conversions in a single `make convert-all` recipe, caching shared Hilbert/interim steps.
- Teach `scripts/quick_probe.py` to export its histogram/FFT artefacts as JSON so CI systems can diff amplitude spectra over time.
