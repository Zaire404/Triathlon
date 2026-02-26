#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
NPC_HOME=$(cd "${SCRIPT_DIR}/.." && pwd)

FW_PAYLOAD="${HOME}/rv32-linux/src/opensbi/build/platform/generic/firmware/fw_payload.bin"
DTB="${HOME}/rv32-linux/out/npc.dtb"
VIRTIO_BLK_IMAGE="${HOME}/rv32-linux/out/rootfs.img"
FIRMWARE_LOAD_BASE="0x80040000"
TIMEOUT_SEC=180
MAX_CYCLES=80000000
PROGRESS=1000000
LOG_DIR="${NPC_HOME}/build/linux-smoke/$(date +%Y%m%d-%H%M%S)"
MARKERS=("OpenSBI" "Linux version")

usage() {
  cat <<'EOF'
Usage: run_linux_smoke.sh [options]
  --fw-payload <path>         OpenSBI fw_payload.bin
  --dtb <path>                DTB path
  --virtio-blk-image <path>   Rootfs block image
  --firmware-load-base <addr> Firmware load base (default: 0x80040000)
  --timeout-sec <n>           Timeout seconds (0 disables timeout)
  --max-cycles <n>            --max-cycles passed to npc
  --progress <n>              --progress passed to npc
  --log-dir <path>            Log output directory
  --marker <text>             Add required log marker (repeatable)
  --clear-default-markers     Require only markers passed by --marker
  -h, --help                  Show help
EOF
}

expand_path() {
  local p="$1"
  if [[ "${p}" == "~" ]]; then
    printf '%s\n' "${HOME}"
    return
  fi
  if [[ "${p}" == "~/"* ]]; then
    printf '%s/%s\n' "${HOME}" "${p#"~/"}"
    return
  fi
  printf '%s\n' "${p}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --fw-payload)
      FW_PAYLOAD="$2"
      shift 2
      ;;
    --dtb)
      DTB="$2"
      shift 2
      ;;
    --virtio-blk-image)
      VIRTIO_BLK_IMAGE="$2"
      shift 2
      ;;
    --firmware-load-base)
      FIRMWARE_LOAD_BASE="$2"
      shift 2
      ;;
    --timeout-sec)
      TIMEOUT_SEC="$2"
      shift 2
      ;;
    --max-cycles)
      MAX_CYCLES="$2"
      shift 2
      ;;
    --progress)
      PROGRESS="$2"
      shift 2
      ;;
    --log-dir)
      LOG_DIR="$2"
      shift 2
      ;;
    --marker)
      MARKERS+=("$2")
      shift 2
      ;;
    --clear-default-markers)
      MARKERS=()
      shift 1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[linux-smoke] ERROR: unknown option '$1'" >&2
      usage >&2
      exit 2
      ;;
  esac
done

FW_PAYLOAD=$(expand_path "${FW_PAYLOAD}")
DTB=$(expand_path "${DTB}")
VIRTIO_BLK_IMAGE=$(expand_path "${VIRTIO_BLK_IMAGE}")
LOG_DIR=$(expand_path "${LOG_DIR}")

if [[ ! -f "${FW_PAYLOAD}" ]]; then
  echo "[linux-smoke] ERROR: fw payload not found: ${FW_PAYLOAD}" >&2
  exit 1
fi
if [[ ! -f "${DTB}" ]]; then
  echo "[linux-smoke] ERROR: dtb not found: ${DTB}" >&2
  exit 1
fi
if [[ ! -f "${VIRTIO_BLK_IMAGE}" ]]; then
  echo "[linux-smoke] ERROR: virtio blk image not found: ${VIRTIO_BLK_IMAGE}" >&2
  exit 1
fi
if [[ "${#MARKERS[@]}" -eq 0 ]]; then
  echo "[linux-smoke] ERROR: no markers configured" >&2
  exit 2
fi

mkdir -p "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/linux-smoke.log"

ARGS="--boot-handoff --dtb ${DTB} --virtio-blk-image ${VIRTIO_BLK_IMAGE} --firmware-load-base ${FIRMWARE_LOAD_BASE} --max-cycles ${MAX_CYCLES} --progress ${PROGRESS}"
CMD=(make sim DIFFTEST= IMG="${FW_PAYLOAD}" ARGS="${ARGS}")

echo "[linux-smoke] npc home: ${NPC_HOME}"
echo "[linux-smoke] log: ${LOG_FILE}"

pushd "${NPC_HOME}" >/dev/null
set +e
if [[ "${TIMEOUT_SEC}" -gt 0 ]]; then
  timeout "${TIMEOUT_SEC}s" "${CMD[@]}" >"${LOG_FILE}" 2>&1
  RC=$?
else
  "${CMD[@]}" >"${LOG_FILE}" 2>&1
  RC=$?
fi
set -e
popd >/dev/null

if [[ "${RC}" -ne 0 ]]; then
  if [[ "${RC}" -eq 124 ]]; then
    echo "[linux-smoke] ERROR: timeout after ${TIMEOUT_SEC}s" >&2
  else
    echo "[linux-smoke] ERROR: make sim exited with ${RC}" >&2
  fi
  tail -n 40 "${LOG_FILE}" | sed 's/^/[linux-smoke] | /' >&2 || true
  exit 1
fi

missing=()
for marker in "${MARKERS[@]}"; do
  if ! grep -q "${marker}" "${LOG_FILE}"; then
    missing+=("${marker}")
  fi
done

if [[ "${#missing[@]}" -ne 0 ]]; then
  echo "[linux-smoke] ERROR: missing markers:" >&2
  for marker in "${missing[@]}"; do
    echo "[linux-smoke]   - ${marker}" >&2
  done
  tail -n 40 "${LOG_FILE}" | sed 's/^/[linux-smoke] | /' >&2 || true
  exit 1
fi

echo "[linux-smoke] PASS"
echo "[linux-smoke] matched markers: ${MARKERS[*]}"
echo "[linux-smoke] log: ${LOG_FILE}"
