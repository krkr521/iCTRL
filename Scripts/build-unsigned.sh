#!/usr/bin/env bash
# No developer login, certificates, profiles, private keys or pairing files.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ "$(uname -s)" == Darwin ]] || { echo "Requires macOS with full Xcode." >&2; exit 1; }
command -v xcodegen >/dev/null || { echo "Install xcodegen (brew install xcodegen)." >&2; exit 1; }
xcodebuild -version
python3 Scripts/test-native-build-manifest.py
swift test
mkdir -p build
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
make ICTRL_UNSIGNED=1 ipa
mkdir -p release
cp iCTRL.ipa iCTRLUITests-Runner.ipa release/
python3 Scripts/native-build-manifest.py release
