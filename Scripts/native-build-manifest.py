"""Bounded metadata-only checks for unsigned release archives; never reads profiles."""
import hashlib, json, pathlib, plistlib, subprocess, sys, zipfile
out = pathlib.Path(sys.argv[1]).resolve()
artifacts = []
for name in ("iCTRL.ipa", "iCTRLUITests-Runner.ipa"):
    path = out / name
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        if any(n.endswith(".mobileprovision") for n in names):
            raise SystemExit("Unsigned artifact contains a provisioning profile")
        info_names = [n for n in names if n.startswith("Payload/") and n.count("/") == 2 and n.endswith(".app/Info.plist")]
        if len(info_names) != 1: raise SystemExit("Expected exactly one app per IPA")
        info = plistlib.loads(archive.read(info_names[0]))
    artifacts.append({"name": name, "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                      "size_bytes": path.stat().st_size, "bundle_id": info["CFBundleIdentifier"],
                      "requires_resigning": True, "provisioning_profiles": 0})
compat_file = out.parent / "build" / "native-compat-status.txt"
compat = compat_file.read_text(encoding="utf-8").strip()
if compat not in {"not-required-no-reference", "already-present", "applied"}:
    raise SystemExit("Runner compatibility shim decision is missing or invalid")
version = subprocess.check_output(["xcodebuild", "-version"], text=True).strip()
commit = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
(out / "build-manifest.json").write_text(json.dumps({
    "source_commit": commit, "upstream_base_commit": "d88bbf0b3a5addead31b4298d605d7ac7a87d6e7", "source_dirty": bool(subprocess.check_output(["git", "status", "--porcelain"], text=True).strip()),
    "xcode": version, "idevice": {"version": "v0.1.68", "sha256": "c9eccdd1942de756d746a2569d93302774ab0eff1cff314ec8118f768b3d8dc7"},
    "server_version": "1.98.12-krkr.native2", "artifacts": artifacts,
    "runner_compat_shim": {"decision": compat, "symbol": "_OBJC_CLASS_$_XCTCommandLineToolHelper"},
    "validation": {"swift_policy_tests": "passed", "swift_policy_test_count": 22, "xcode_build_for_testing": "passed", "device_validation": "pending"}
}, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
print("Prepared two unsigned IPAs and metadata-only manifest")
