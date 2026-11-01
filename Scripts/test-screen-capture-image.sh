#!/usr/bin/env bash
# UIKit-only tests in an existing iOS Simulator; no real phone, pairing or signing.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ "$(uname -s)" == Darwin ]] || { echo "Requires macOS with full Xcode and an installed iOS Simulator." >&2; exit 1; }
command -v xcodegen >/dev/null || { echo "Requires xcodegen." >&2; exit 1; }
mkdir -p build/screen-capture-image
xcodegen generate --spec Tests/ScreenCaptureImage/project.yml --project build/screen-capture-image
simulator_id="$(xcrun simctl list devices available --json | python3 -c '
import json, sys
devices = json.load(sys.stdin)["devices"]
candidates = [device for runtime, values in devices.items() if ".iOS-" in runtime
              for device in values if device.get("isAvailable") and device.get("name", "").startswith("iPhone")]
if not candidates:
    raise SystemExit("No installed iPhone Simulator is available; no runtime will be downloaded.")
candidates.sort(key=lambda device: device.get("state") != "Booted")
print(candidates[0]["udid"])
')"
xcodebuild test \
  -project build/screen-capture-image/ScreenCaptureImage.xcodeproj \
  -scheme ScreenCaptureImageTests \
  -destination "platform=iOS Simulator,id=$simulator_id" \
  -derivedDataPath build/screen-capture-image/DerivedData \
  CODE_SIGNING_ALLOWED=NO
