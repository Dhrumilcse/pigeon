#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

DEVICE_ID="779DF284-71E3-578E-A480-345C7F19CD39"
DERIVED_DATA="/tmp/pigeon-deriveddata-device"
APP_PATH="${DERIVED_DATA}/Build/Products/Debug-iphoneos/Pigeon.app"

xcodebuild \
  -project Pigeon.xcodeproj \
  -scheme Pigeon \
  -configuration Debug \
  -destination "platform=iOS,id=${DEVICE_ID}" \
  -derivedDataPath "${DERIVED_DATA}" \
  -allowProvisioningUpdates \
  build

xcrun devicectl device install app \
  --device "${DEVICE_ID}" \
  "${APP_PATH}"
