#!/bin/sh
# Pure Swift checks; no signing, iPhone, or touch injection required.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/ictrl-path-tests.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
swiftc -module-cache-path "$tmp/module-cache" \
    "$root/iCTRLKit/RPCCoreTypes.swift" \
    "$root/iCTRLUITests/ActionCommand.swift" \
    "$root/iCTRLUITests/ContinuousDragPath.swift" \
    "$root/Tests/ContinuousDragPath/main.swift" \
    -o "$tmp/continuous-drag-tests"
"$tmp/continuous-drag-tests"
