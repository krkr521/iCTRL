# Native clipboard and on-device renewal

This change adds native plain-text clipboard RPCs, foreground keep-awake support,
runtime readiness metadata, and AppIntents for starting iCTRL and coordinating
renewal from an iPhone Shortcuts personal automation.

## Clipboard and readiness

Authenticated clients can discover `native_clipboard_v1` and call
`clipboard_get`, `clipboard_set`, and `clipboard_clear`. Text is limited to
65,536 UTF-8 bytes and must not contain NUL. Operations may temporarily bring
the Runner forward and restore the previous app. The first read may require
the iPhone's Allow Paste permission. An ambiguous timeout must not be replayed
or retried through a different clipboard implementation.

`runtime_status` exposes service/DDI readiness and the Runner's own provisioning
expiry. A nonce-bound companion handoff can supply companion metadata, but is
explicitly marked as a local report rather than authenticated process identity.
No complete provisioning profile, certificate, pairing record, or private key is
returned by these new methods.

Keep-awake uses UIKit's idle timer only while the corresponding app is in the
foreground. It does not change the system Auto-Lock setting or prevent locking
while unrelated apps are in the foreground.

## Phone-local Shortcuts

The companion exposes these actions:

- Check iCTRL Readiness
- Prepare iCTRL
- Record iCTRL Renewal Progress
- Plan iCTRL Renewal
- Begin iCTRL Renewal
- Finalize iCTRL Renewal
- Complete iCTRL Renewal Recovery

A personal automation can check daily while the native gate permits renewal
on the fifth local calendar day after a verified success. The first baseline
uses actual profile expiries with a two-day lead instead of inventing a success
timestamp. State and attempt reservations remain on the iPhone.

Reserve the task before switching VPNs, mount the cached DDI if necessary,
capture the original profile dates, and authorize one refresh attempt. Invoke
the installed sideloading app's refresh action, record the matching completion
receipt, then finalize. Finalization requires both profile dates to advance and
at least six days of remaining validity. The sideloading app's own profile is
outside iCTRL's sandbox and is not independently read by this implementation.

Use a separate conditional recovery automation because a sideloading app may
exit while refreshing itself. Normal checks do not switch VPNs or bring iCTRL
forward. Actual VPN configurations must be selected on the user's own device;
no account, server address, or VPN authentication key is built into this code.

Locked-device restrictions, first-run permissions, Apple authentication, and DDI
requirements still apply. Validate the setup on the target device before relying
on unattended renewal.

## Build

Run `bash Scripts/build-unsigned.sh` on macOS with Xcode 16.4 and XcodeGen. The
script runs Foundation policy and continuous drag tests, verifies the downloaded IDevice dependency,
and builds two artifacts without an Apple account. The IPAs require signing on
the user's device or with the user's own development setup. Build outputs and
local signing configuration are excluded from Git.

The upstream Apache-2.0 license and notices remain in place.

## Upstream integration

Version `1.98.13-krkr.native3` merges upstream main at `874f528` and
[PR #6](https://github.com/OpenMinis/iCTRL/pull/6), adding continuous single-finger
drag paths. It retains the native clipboard and renewal actions. The path tests
use the fork's split core types, and long paths retain post-action settling
within their extended watchdog budget. Device validation of this integration is
reported separately from compilation and policy tests.

Version `1.98.13-krkr.native4` adds explicit encrypted file-transfer queues and a
Share Extension. The extension pairs independently with the Runner. Incoming
computer files stay pending until the companion is foreground, verifies them,
and saves them without overwriting existing files in its Documents directory.
That directory is exposed as iCTRL in Files. Pairing records and DDI data remain
in Application Support. Saved acknowledgements are client reports, not process
attestation. Chunks are limited to 192 KiB and each file to 256 MiB.

Debug builds also expose `shade_probe` as a single-attempt experiment on an
existing XCTest session. Inspection is non-mutating by default. An explicit
restore call has no safe cancellation hook and must not be retried after a
timeout. Its return value does not establish physical screen state; the system
overlay is omitted from XCTest screenshots. No automatic shade policy is
enabled by this build.

Version `1.98.13-krkr.native9` separates foreground activation admission from
post-activation fresh PID confirmation while retaining the existing callback,
lease and restoration limits. Manual owner status reports relative recovery
check availability. `runtime_status` and `device_info` also return the OS's
version/build description to support investigation against matching firmware.
This build does not claim to fix the system Automation Running shade fading
during synthesized input; physical display behavior still needs a verified
system interface and direct observation.

Debug builds additionally expose `shade_system_artifact` for matching-build
offline investigation. It accepts only `artifact: automation_ui`, referring to
one fixed Apple AutomationModeUI executable. It uses ordinary sandbox file
access, checks a regular Mach-O file through the same open handle, limits the
file to 2 MiB and each encrypted chunk to 48 KiB, and returns only metadata by
default. Arbitrary paths, other app data and unknown parameters are rejected.
Denied/missing/oversized reads return finite status values; there is no fallback
path, permission bypass or system write. No binary payload or error description
is written to the diagnostic log. Extracted Apple binaries are private local
research artifacts and must not be included in this repository or releases.
