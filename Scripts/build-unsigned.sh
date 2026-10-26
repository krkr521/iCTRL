#!/usr/bin/env bash
# No developer login, certificates, profiles, private keys or pairing files.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ "$(uname -s)" == Darwin ]] || { echo "Requires macOS with full Xcode." >&2; exit 1; }
command -v xcodegen >/dev/null || { echo "Install xcodegen (brew install xcodegen)." >&2; exit 1; }
xcodebuild -version
python3 Scripts/test-native-build-manifest.py
mkdir -p build
swift test | tee build/swift-policy-tests.log
./Scripts/test-continuous-drag.sh | tee build/continuous-drag-tests.log
mkdir -p build/dependencies
archive="$PWD/build/dependencies/idevice-xcframework-v0.1.68.zip"
if [[ ! -f "$archive" ]]; then
  curl --fail --location --retry 3 --connect-timeout 20 --max-time 600 \
    'https://github.com/jkcoxson/idevice/releases/download/v0.1.68/idevice-xcframework-v0.1.68.zip' -o "$archive"
fi
expected=c9eccdd1942de756d746a2569d93302774ab0eff1cff314ec8118f768b3d8dc7
actual="$(shasum -a 256 "$archive" | awk '{print $1}')"
[[ "$actual" == "$expected" ]] || { echo "IDevice archive checksum mismatch." >&2; exit 1; }
IDEVICE_ZIP="$archive" IDEVICE_VERSION=v0.1.68 bash Scripts/fetch-idevice.sh
# The generated XCTest host does not exist during the test target's own
# postBuild phase. Wait for build-for-testing/CreateTestRunnerProduct to finish.
make ICTRL_UNSIGNED=1 build
python3 -c '
import pathlib, plistlib
products = pathlib.Path("build/Build/Products/Debug-iphoneos")
main = products / "iCTRL.app/Info.plist"
runner = products / "iCTRLUITests-Runner.app/Info.plist"
source = plistlib.loads(main.read_bytes())
raw = runner.read_bytes()
target = plistlib.loads(raw)
for key in ("CFBundleShortVersionString", "CFBundleVersion"):
    value = source.get(key)
    if not isinstance(value, str) or not value.strip():
        raise SystemExit("Main app version metadata missing: " + key)
    target[key] = value
runner.write_bytes(plistlib.dumps(target, fmt=plistlib.FMT_BINARY if raw.startswith(b"bplist") else plistlib.FMT_XML))
print("Stamped generated Runner host from actual Main app version metadata")
'
# Treat build as already complete: ipa still performs every packaging step,
# without rerunning xcodebuild and replacing the just-stamped generated host.
make ICTRL_UNSIGNED=1 -o build ipa
mkdir -p release
cp iCTRL.ipa iCTRLUITests-Runner.ipa release/
python3 Scripts/native-build-manifest.py release
