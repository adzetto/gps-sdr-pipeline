#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="$ROOT_DIR/logs"
REPO_DIR="$ROOT_DIR/external/GPS-SDR-Receiver"
CONFIG_FILE="$REPO_DIR/src/gpsglob.py"
DEFAULT_BIN="$ROOT_DIR/data/processed/TGS_L1_E1_2p048Msps_iq_u8.bin"
DEFAULT_LOG="$LOG_DIR/run.log"
PYTHON_BIN="${PYTHON_BIN:-$ROOT_DIR/env/.venv/bin/python}"
VALIDATOR="$ROOT_DIR/scripts/validate_run.py"
MIN_PRN="${RUN_MIN_PRN:-1}"
REQUIRE_TASK_FINISH="${RUN_REQUIRE_TASK_FINISH:-1}"

usage() {
  cat <<'EOF'
Usage: run_receiver_offline.sh [--input IQ_BIN] [--log LOG_FILE] [--python PYTHON_BIN]
  --input   Path to IQ file (default data/processed/TGS_L1_E1_2p048Msps_iq_u8.bin)
  --log     Log output file (default logs/run.log)
  --python  Python interpreter for gpssdr.py (default env/.venv/bin/python)
EOF
}

normalize_path() {
  python3 - "$ROOT_DIR" "$1" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
target = Path(sys.argv[2]).expanduser()
if not target.is_absolute():
    target = root / target
print(target.resolve())
PY
}

INPUT_ARG=""
LOG_ARG=""
PYTHON_ARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --input)
      INPUT_ARG="$2"
      shift 2
      ;;
    --log)
      LOG_ARG="$2"
      shift 2
      ;;
    --python)
      PYTHON_ARG="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -n "$PYTHON_ARG" ]]; then
  PYTHON_BIN="$PYTHON_ARG"
fi

mkdir -p "$LOG_DIR"

if [[ ! -x "$PYTHON_BIN" ]]; then
  echo "Python interpreter $PYTHON_BIN not found. Run 'make init' first." >&2
  exit 1
fi

VENV_BIN_DIR="$(dirname "$PYTHON_BIN")"
export PATH="$VENV_BIN_DIR:$PATH"
export QT_QPA_PLATFORM="${QT_QPA_PLATFORM:-offscreen}"

IQ_PATH="$(normalize_path "${INPUT_ARG:-$DEFAULT_BIN}")"
LOG_PATH="$(normalize_path "${LOG_ARG:-$DEFAULT_LOG}")"
BIN_NAME="$(basename "$IQ_PATH")"
BIN_DIR="$(dirname "$IQ_PATH")"

if [[ ! -f "$IQ_PATH" ]]; then
  echo "IQ file not found: $IQ_PATH" >&2
  exit 1
fi

mkdir -p "$(dirname "$LOG_PATH")"

backup=$(mktemp)
cp "$CONFIG_FILE" "$backup"
restore() {
  mv "$backup" "$CONFIG_FILE"
}
trap restore EXIT

python3 - "$CONFIG_FILE" "$BIN_NAME" "$BIN_DIR" <<'PY'
import re
from pathlib import Path
import sys
cfg = Path(sys.argv[1])
bin_name = sys.argv[2]
rel_path = Path(sys.argv[3]).as_posix()
text = cfg.read_text()
text = re.sub(r"LIVE_MEAS = .*", "LIVE_MEAS = False", text)
text = re.sub(r"BIN_DATA = .*", f"BIN_DATA = {bin_name!r}", text)
text = re.sub(r"REL_PATH = .*", f"REL_PATH = {rel_path!r}", text)
cfg.write_text(text)
PY

pushd "$REPO_DIR" >/dev/null
"$PYTHON_BIN" gpssdr.py 2>&1 | tee "$LOG_PATH"
popd >/dev/null
if [[ -f "$VALIDATOR" ]]; then
  validate_args=(--log "$LOG_PATH" --min-prn "$MIN_PRN")
  if [[ "$REQUIRE_TASK_FINISH" != "0" ]]; then
    validate_args+=(--require-task-finish)
  fi
  "$PYTHON_BIN" "$VALIDATOR" "${validate_args[@]}"
fi
