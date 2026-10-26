"""Bounded metadata-only checks for unsigned release archives; never reads profiles."""
import hashlib, json, pathlib, plistlib, re, subprocess, sys, zipfile
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
        # Validate every embedded extension, including a missing extension plist.
        # Signing services reject missing or divergent extension version metadata.
        extension_roots = set()
        for member in names:
            components = member.split("/")
            for index, component in enumerate(components):
                if component.endswith(".appex"):
                    extension_roots.add("/".join(components[:index + 1]))
        for extension in sorted(extension_roots):
            extension_plist = extension + "/Info.plist"
            app_parents = [extension[:index + 4] for index in range(len(extension))
                           if extension[index:index + 5] == ".app/"]
            if not app_parents or extension_plist not in names:
                raise SystemExit("Embedded appex is missing its parent app or Info.plist")
            parent_plist = app_parents[-1] + "/Info.plist"
            if parent_plist not in names:
                raise SystemExit("Embedded appex parent Info.plist is missing")
            parent = plistlib.loads(archive.read(parent_plist))
            embedded = plistlib.loads(archive.read(extension_plist))
            for key in ("CFBundleShortVersionString", "CFBundleVersion"):
                if not isinstance(parent.get(key), str) or not parent[key] or not isinstance(embedded.get(key), str) or embedded[key] != parent[key]:
                    raise SystemExit("Embedded appex version/build metadata is missing or differs from parent: " + key)
    artifacts.append({"name": name, "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                      "size_bytes": path.stat().st_size, "bundle_id": info["CFBundleIdentifier"],
                      "requires_resigning": True, "provisioning_profiles": 0})
compat_file = out.parent / "build" / "native-compat-status.txt"
compat = compat_file.read_text(encoding="utf-8").strip()
if compat not in {"not-required-no-reference", "already-present", "applied"}:
    raise SystemExit("Runner compatibility shim decision is missing or invalid")
path_report_file = out.parent / "build" / "continuous-drag-tests.log"
path_report = path_report_file.read_text(encoding="utf-8") if path_report_file.exists() else ""
path_match = re.fullmatch(r"ContinuousDragPath: ([1-9][0-9]*) checks passed\s*", path_report)
if not path_match:
    raise SystemExit("Continuous drag test result is missing or invalid")
policy_file = out.parent / "build" / "swift-policy-tests.log"
policy_report = policy_file.read_text(encoding="utf-8") if policy_file.exists() else ""
policy_results = re.findall(r"Executed ([1-9][0-9]*) tests?, with ([0-9]+) failures?", policy_report)
if not policy_results or any(int(failures) != 0 for _, failures in policy_results):
    raise SystemExit("Swift policy test result is missing or contains failures")
policy_count = max(int(count) for count, _ in policy_results)
version = subprocess.check_output(["xcodebuild", "-version"], text=True).strip()
commit = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
(out / "build-manifest.json").write_text(json.dumps({
    "source_commit": commit, "upstream_base_commit": "874f528759b1b977971a06cc4a3594d169eb77b9", "source_dirty": bool(subprocess.check_output(["git", "status", "--porcelain"], text=True).strip()),
    "upstream_pr": {"number": 6, "head": "2b5fcfc632f83362ab7d00d42f1012d6920d0c55"},
    "xcode": version, "idevice": {"version": "v0.1.68", "sha256": "c9eccdd1942de756d746a2569d93302774ab0eff1cff314ec8118f768b3d8dc7"},
    "server_version": "1.98.13-krkr.native4", "artifacts": artifacts,
    "runner_compat_shim": {"decision": compat, "symbol": "_OBJC_CLASS_$_XCTCommandLineToolHelper"},
    "validation": {"swift_policy_tests": "passed", "swift_policy_test_count": policy_count,
                   "continuous_drag_checks_passed": int(path_match.group(1)),
                   "xcode_build_for_testing": "passed", "device_validation": "pending"}
}, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
print("Prepared two unsigned IPAs and metadata-only manifest")
