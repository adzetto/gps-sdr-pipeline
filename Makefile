ROOT := $(CURDIR)
POSIX_VENV := env/.venv
WIN_VENV := env/.venv-win
RAW ?=
ifeq ($(RAW),)
RAW := $(firstword $(foreach f,data/raw/TGS_L1_E1.dat data/raw/TGS_L1_E1-002.dat,$(if $(wildcard $(f)),$(f))))
ifeq ($(RAW),)
RAW := data/raw/TGS_L1_E1.dat
endif
endif
RAW_DTYPE ?= int8
PROCESSED := data/processed/TGS_L1_E1_2p048Msps_iq_u8.bin
PROCESSED_4M := data/processed/TGS_L1_E1_4p096Msps_iq_u8.bin

ifeq ($(OS),Windows_NT)
SHELL := pwsh.exe
.SHELLFLAGS := -NoProfile -NoLogo -ExecutionPolicy Bypass -Command
WINDOWS := 1
VENV := $(WIN_VENV)
PYTHON := $(VENV)/Scripts/python.exe
PIP := $(VENV)/Scripts/pip.exe
else
SHELL := /bin/bash
.SHELLFLAGS := -euo pipefail -c
WINDOWS := 0
VENV := $(POSIX_VENV)
PYTHON := $(VENV)/bin/python
PIP := $(VENV)/bin/pip
endif

.PHONY: init fetch probe convert convert-4m run run-sample all clean

ifeq ($(WINDOWS),1)

init:
	./scripts/windows/init_env.ps1 -VenvRelative "$(VENV)"

fetch:
	./scripts/windows/fetch_data.ps1

probe:
	./scripts/windows/quick_probe.ps1 -Raw "$(RAW)" -Output "plots/raw_hist.png" -VenvRelative "$(VENV)" -SampleDType "$(RAW_DTYPE)"

convert:
	./scripts/windows/convert_dat_to_bin.ps1 -VenvRelative "$(VENV)"

convert-4m:
	./scripts/windows/convert_dat_to_bin.ps1 -VenvRelative "$(VENV)" -Config "configs/pipeline_4Msps.yaml"

run:
	./scripts/windows/run_receiver_offline.ps1 -VenvRelative "$(VENV)"

run-sample:
	./scripts/windows/run_receiver_offline.ps1 -Input "external/GPS-SDR-Receiver/data/test.bin" -LogFile "logs/run_sample.log" -VenvRelative "$(VENV)"

clean:
	./scripts/windows/clean_workspace.ps1

else

init:
	@if [ ! -d $(VENV) ]; then \
		python3 -m venv $(VENV) || ( \
			python3 -m venv --without-pip $(VENV) && \
			curl -sS https://bootstrap.pypa.io/get-pip.py -o $(VENV)/get-pip.py && \
			$(VENV)/bin/python $(VENV)/get-pip.py \
		); \
	fi
	$(PYTHON) -m pip install --upgrade pip
	$(PYTHON) -m pip install -r external/GPS-SDR-Receiver/requirements.txt
	$(PYTHON) -m pip install numpy scipy matplotlib tqdm pyyaml

fetch:
	./scripts/fetch_data.sh

probe:
	@[ -f $(RAW) ] || { echo "$(RAW) missing. Run make fetch or set FAIRDATA_DIRECT_URL."; exit 1; }
	$(PYTHON) scripts/quick_probe.py $(RAW) --output plots/raw_hist.png --dtype $(RAW_DTYPE)

convert:
	$(PYTHON) scripts/convert_dat_to_bin.py --config configs/pipeline.yaml --root $(ROOT)

convert-4m:
	$(PYTHON) scripts/convert_dat_to_bin.py --config configs/pipeline_4Msps.yaml --root $(ROOT)

run:
	./scripts/run_receiver_offline.sh

run-sample:
	./scripts/run_receiver_offline.sh --input external/GPS-SDR-Receiver/data/test.bin --log logs/run_sample.log

clean:
	rm -f data/interim/* data/processed/*.bin data/processed/*.json
	rm -f logs/*.log plots/*.png

endif

all: init fetch convert run
