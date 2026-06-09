#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

DEVICE_ID="779DF284-71E3-578E-A480-345C7F19CD39"
DERIVED_DATA="/tmp/pigeon-deriveddata-device"
APP_PATH="${DERIVED_DATA}/Build/Products/Debug-iphoneos/Pigeon.app"
LOG_FILE="$(mktemp -t pigeon-build.XXXXXX.log)"

finish() {
  local status=$?
  if [[ ${status} -eq 0 ]]; then
    rm -f "${LOG_FILE}"
  else
    echo
    echo "Full log: ${LOG_FILE}"
  fi
}
trap finish EXIT

step() {
  echo "==> $1"
}

run_quiet() {
  local label="$1"
  shift

  if "$@" >>"${LOG_FILE}" 2>&1; then
    return 0
  fi

  echo
  echo "Failed: ${label}"
  echo "--- Relevant log lines ---"
  if grep -q "^xcodebuild: error:" "${LOG_FILE}"; then
    grep -A20 "^xcodebuild: error:" "${LOG_FILE}"
  else
    grep -E "(: error:|^error:|^fatal:|\\*\\* BUILD FAILED \\*\\*|The following build commands failed)" "${LOG_FILE}" \
      | tail -60 \
      || tail -40 "${LOG_FILE}"
  fi
  return 1
}

step "Building Pigeon"
run_quiet "xcodebuild" \
  xcodebuild \
    -project Pigeon.xcodeproj \
    -scheme Pigeon \
    -configuration Debug \
    -destination "platform=iOS,id=${DEVICE_ID}" \
    -derivedDataPath "${DERIVED_DATA}" \
    -allowProvisioningUpdates \
    build
step "Build succeeded"

step "Installing on device"
run_quiet "device install" \
  xcrun devicectl device install app \
    --device "${DEVICE_ID}" \
    "${APP_PATH}"
step "Installed"
