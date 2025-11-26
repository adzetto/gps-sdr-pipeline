from pathlib import Path
import numpy as np
import matplotlib.pyplot as plt
import scienceplots
from scipy import signal
import re
plt.style.use(['science','grid'])
DATA_PATH = Path('../data/processed/TGS_L1_E1_2p048Msps_iq_u8.bin')
LOG_PATH = Path('../logs/run_fairdata.log')
FS_HZ = 2_048_000
WINDOW_SAMPLES = FS_HZ * 2  # analyze first 2 seconds
N_PER_SEG = 8192
N_OVERLAP = 6144
FREQ_DECIMATION = 4
TIME_DECIMATION = 2
FIG_DPI = 300
PRN_PATTERN = re.compile(r"PRN\s+(\d+)\s+Corr:([0-9.]+)\s+f=([+\-0-9.]+)")

def load_iq(path: Path, max_samples: int) -> np.ndarray:
    data = np.fromfile(path, dtype=np.uint8, count=2 * max_samples)
    if data.size < 2:
        raise RuntimeError('File is empty or shorter than requested window')
    data = (data.astype(np.float32) - 128.0) / 128.0
    i = data[0::2]
    q = data[1::2]
    return (i + 1j * q)[:max_samples]


def parse_prn_log(path: Path) -> dict[int, dict[str, float]]:
    info = {}
    if not path.exists():
        return info
    with path.open() as fh:
        for line in fh:
            match = PRN_PATTERN.search(line)
            if match:
                prn = int(match.group(1))
                info[prn] = {
                    'corr': float(match.group(2)),
                    'doppler_hz': float(match.group(3)),
                }
    return info
iq = load_iq(DATA_PATH, WINDOW_SAMPLES)
prn_info = parse_prn_log(LOG_PATH)
print(f'Loaded {iq.size} IQ samples (first {WINDOW_SAMPLES})')
print('PRNs from log:', prn_info)
print('Computing STFT...')
f, t, Zxx = signal.stft(iq, fs=FS_HZ, nperseg=N_PER_SEG, noverlap=N_OVERLAP, boundary=None, padded=False, return_onesided=False)
print(f'STFT done: Zxx shape {Zxx.shape}')
power = 20.0 * np.log10(np.abs(Zxx) + 1e-12)
print('Computed power spectrum')
f_shift = np.fft.fftshift(f) / 1e3  # kHz
t_seconds = t
power_shift = np.fft.fftshift(power, axes=0).astype(np.float32, copy=False)
print('Shifted frequency axis for plotting')

# Downsample spectrogram grid to keep plotting memory reasonable
power_plot = power_shift
f_plot = f_shift
t_plot = t_seconds
if FREQ_DECIMATION > 1:
    power_plot = power_plot[::FREQ_DECIMATION, :]
    f_plot = f_plot[::FREQ_DECIMATION]
if TIME_DECIMATION > 1:
    power_plot = power_plot[:, ::TIME_DECIMATION]
    t_plot = t_plot[::TIME_DECIMATION]
print(f'Plot grid shape after decimation: {power_plot.shape}')
fig, ax = plt.subplots(figsize=(10, 5))
mesh = ax.pcolormesh(t_plot, f_plot, power_plot, shading='gouraud', cmap='magma')
for prn, meta in prn_info.items():
    ax.axhline(meta['doppler_hz'] / 1e3, linestyle='--', label=f"PRN {prn}")
ax.set_xlabel('Time (s)')
ax.set_ylabel('Frequency (kHz)')
ax.set_title('STFT magnitude (dB) with Doppler overlays')
if prn_info:
    ax.legend(loc='upper right', fontsize='small')
fig.colorbar(mesh, ax=ax, label='Magnitude (dB)')
fig.tight_layout()
print('Saving figure...')
plt.savefig('stft_with_doppler.png', dpi=FIG_DPI)
plt.show()
print('Done.')
