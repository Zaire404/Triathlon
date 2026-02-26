#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RUN_SCRIPT="${SCRIPT_DIR}/run_linux_smoke.sh"

TMP_DIR=$(mktemp -d)
trap 'rm -rf "${TMP_DIR}"' EXIT

FAKE_BIN="${TMP_DIR}/fake-bin"
mkdir -p "${FAKE_BIN}"

FW_PAYLOAD="${TMP_DIR}/fw_payload.bin"
DTB="${TMP_DIR}/npc.dtb"
BLK_IMG="${TMP_DIR}/rootfs.img"
LOG_DIR="${TMP_DIR}/logs"
MAKE_LOG="${TMP_DIR}/make.log"

printf '\x13\x00\x00\x00' > "${FW_PAYLOAD}"
printf '\xd0\x0d\xfe\xed' > "${DTB}"
dd if=/dev/zero of="${BLK_IMG}" bs=512 count=1 status=none

cat > "${FAKE_BIN}/make" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "make $*" >> "${MAKE_LOG:?}"
if [[ "${SIM_BEHAVIOR:-pass}" == "pass" ]]; then
  echo "OpenSBI v1.5"
  echo "Linux version 6.6.0"
else
  echo "OpenSBI v1.5"
fi
EOF
chmod +x "${FAKE_BIN}/make"

if ! PATH="${FAKE_BIN}:${PATH}" \
  MAKE_LOG="${MAKE_LOG}" \
  SIM_BEHAVIOR=pass \
  bash "${RUN_SCRIPT}" \
    --fw-payload "${FW_PAYLOAD}" \
    --dtb "${DTB}" \
    --virtio-blk-image "${BLK_IMG}" \
    --timeout-sec 0 \
    --max-cycles 1000 \
    --progress 100 \
    --log-dir "${LOG_DIR}" >/dev/null 2>&1; then
  echo "expected smoke script to pass with markers present" >&2
  exit 1
fi

if ! grep -q "virtio-blk-image ${BLK_IMG}" "${MAKE_LOG}"; then
  echo "missing virtio blk arg in make invocation" >&2
  cat "${MAKE_LOG}" >&2
  exit 1
fi

set +e
PATH="${FAKE_BIN}:${PATH}" \
MAKE_LOG="${MAKE_LOG}" \
SIM_BEHAVIOR=fail \
bash "${RUN_SCRIPT}" \
  --fw-payload "${FW_PAYLOAD}" \
  --dtb "${DTB}" \
  --virtio-blk-image "${BLK_IMG}" \
  --timeout-sec 0 \
  --max-cycles 1000 \
  --progress 100 \
  --log-dir "${LOG_DIR}" >/dev/null 2>&1
RC=$?
set -e

if [[ "${RC}" -eq 0 ]]; then
  echo "expected smoke script to fail when Linux marker is missing" >&2
  exit 1
fi

echo "PASS"
