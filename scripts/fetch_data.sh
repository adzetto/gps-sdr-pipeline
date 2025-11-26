#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="$ROOT_DIR/logs"
LOG_FILE="$LOG_DIR/fetch.log"
RAW_DIR="$ROOT_DIR/data/raw"
CHECKSUM_MANIFEST="${CHECKSUM_MANIFEST:-$ROOT_DIR/configs/checksums.txt}"
mkdir -p "$LOG_DIR" "$RAW_DIR"

log() {
  printf '[%s] [fetch] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$1" | tee -a "$LOG_FILE"
}

download_with_resume() {
  local url="$1"; shift
  local output="$1"; shift
  if [[ -z "$url" ]]; then
    log "No URL provided for $output; skipping"
    return 1
  fi
  log "Starting download: $url -> $output"
  if ! curl -L --retry 5 --retry-delay 5 -C - -o "$output" "$url"; then
    log "Download failed for $url"
    return 1
  fi
  log "Completed download: $(du -h "$output" | awk '{print $1}') saved to $output"
}

verify_sha256() {
  local file="$1"; shift
  local expected="$1"; shift
  if [[ -z "$expected" ]]; then
    return 0
  fi
  log "Verifying SHA-256 for $file"
  local actual
  actual=$(sha256sum "$file" | awk '{print $1}')
  if [[ "$actual" != "$expected" ]]; then
    log "SHA-256 mismatch for $file: expected $expected got $actual"
    return 1
  fi
  log "SHA-256 OK for $file"
}

manifest_checksum() {
  local basename="$1"
  if [[ ! -f "$CHECKSUM_MANIFEST" ]]; then
    return 1
  fi
  awk -v target="$basename" '
    /^[[:space:]]*#/ { next }
    NF < 2 { next }
    $1 == target { print $2 }
  ' "$CHECKSUM_MANIFEST"
}

verify_with_manifest() {
  local path="$1"
  local fallback="$2"
  local base
  base=$(basename "$path")
  local checksum="${fallback:-}"
  if [[ -z "$checksum" ]]; then
    checksum=$(manifest_checksum "$base")
    if [[ -n "$checksum" ]]; then
      log "Using manifest checksum for $base"
    fi
  fi
  verify_sha256 "$path" "$checksum"
}

check_disk_space() {
  local required_bytes="$1"
  local available
  available=$(df --output=avail -B1 "$ROOT_DIR" | tail -n 1)
  if (( available < required_bytes )); then
    log "Insufficient disk space. Required: $required_bytes bytes, available: $available"
    return 1
  fi
}

main() {
  local fair_url="${FAIRDATA_DIRECT_URL:-}"
  local fair_sha="${FAIRDATA_SHA256:-}"
  local hidrive_url="${HIDRIVE_FILE_URL:-}"
  local hidrive_name="${HIDRIVE_FILENAME:-hidrive_sample.bin}"

  log "Fetch pipeline started"
  check_disk_space $((5 * 1024 * 1024 * 1024)) || log "Warning: less than 5GB free"

  if [[ -n "$fair_url" ]]; then
    local fair_dest="$RAW_DIR/TGS_L1_E1.dat"
    download_with_resume "$fair_url" "$fair_dest"
    verify_with_manifest "$fair_dest" "$fair_sha"
  else
    log "FAIRDATA_DIRECT_URL not set. Please obtain a direct download link from https://etsin.fairdata.fi/dataset/367379a8-7d78-4b08-91f0-8027ce7a621b/data and export FAIRDATA_DIRECT_URL before rerunning."
  fi

  if [[ -n "$hidrive_url" ]]; then
    local hidrive_dest="$RAW_DIR/$hidrive_name"
    download_with_resume "$hidrive_url" "$hidrive_dest"
    verify_with_manifest "$hidrive_dest" ""
  else
    log "HIDRIVE_FILE_URL not set. Provide a signed HiDrive link to fetch long test data (e.g., 230914_data_90s.bin)."
  fi

  log "Fetch pipeline finished"
}

main "$@"
