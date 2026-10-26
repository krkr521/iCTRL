"""Packaging privacy/manifest regression checks; no real Apple artifacts or identity."""
import contextlib, hashlib, io, json, pathlib, plistlib, runpy, sys, tempfile, unittest, zipfile
from unittest.mock import patch

SCRIPT = pathlib.Path(__file__).with_name("native-build-manifest.py")

class NativeBuildManifestTests(unittest.TestCase):
    def fixture(self, folder, profile=False):
        (folder.parent / "build").mkdir(exist_ok=True)
        (folder.parent / "build" / "native-compat-status.txt").write_text("not-required-no-reference\n", encoding="utf-8")
        (folder.parent / "build" / "continuous-drag-tests.log").write_text("ContinuousDragPath: 189 checks passed\n", encoding="utf-8")
        (folder.parent / "build" / "swift-policy-tests.log").write_text("Executed 29 tests, with 0 failures (0 unexpected)\n", encoding="utf-8")
        for name, app in [("iCTRL.ipa", "iCTRL"), ("iCTRLUITests-Runner.ipa", "iCTRLUITests-Runner")]:
            with zipfile.ZipFile(folder / name, "w") as archive:
                archive.writestr(f"Payload/{app}.app/Info.plist", plistlib.dumps({"CFBundleIdentifier": "test." + app, "CFBundleShortVersionString": "1.0.0", "CFBundleVersion": "1"}))
                if profile: archive.writestr(f"Payload/{app}.app/embedded.mobileprovision", b"must-not-be-read")

    def add_extension(self, folder, metadata, extension="iCTRLShare"):
        with zipfile.ZipFile(folder / "iCTRL.ipa", "a") as archive:
            root = f"Payload/iCTRL.app/PlugIns/{extension}.appex"
            archive.writestr(root + "/binary", b"fixture")
            if metadata is not None:
                archive.writestr(root + "/Info.plist", plistlib.dumps(metadata))

    def test_matching_embedded_extension_versions_are_accepted(self):
        with tempfile.TemporaryDirectory(prefix="native-manifest-") as temp:
            folder = pathlib.Path(temp) / "release"
            folder.mkdir()
            self.fixture(folder)
            metadata = {"CFBundleShortVersionString": "1.0.0", "CFBundleVersion": "1"}
            self.add_extension(folder, metadata)
            self.add_extension(folder, metadata, extension="SecondShare")
            self.run_manifest(folder)
            self.assertTrue((folder / "build-manifest.json").exists())

    def test_missing_or_mismatched_extension_versions_fail(self):
        baseline = {"CFBundleShortVersionString": "1.0.0", "CFBundleVersion": "1"}
        variants = [None, {}]
        for key in baseline:
            missing = dict(baseline); missing.pop(key); variants.append(missing)
            divergent = dict(baseline); divergent[key] = "99"; variants.append(divergent)
            empty = dict(baseline); empty[key] = ""; variants.append(empty)
        for metadata in variants:
            with self.subTest(metadata=metadata), tempfile.TemporaryDirectory(prefix="native-manifest-") as temp:
                folder = pathlib.Path(temp) / "release"
                folder.mkdir()
                self.fixture(folder)
                # Ensure validation checks every extension rather than only the first.
                self.add_extension(folder, baseline, extension="FirstValid")
                self.add_extension(folder, metadata, extension="SecondInvalid")
                with self.assertRaisesRegex(SystemExit, "appex"):
                    self.run_manifest(folder)
                self.assertFalse((folder / "build-manifest.json").exists())

    def run_manifest(self, folder):
        outputs = ["Xcode test\n", "test-commit\n", ""]
        with patch.object(sys, "argv", [str(SCRIPT), str(folder)]), patch("subprocess.check_output", side_effect=outputs), contextlib.redirect_stdout(io.StringIO()):
            runpy.run_path(str(SCRIPT), run_name="__main__")

    def test_emits_exactly_two_hashed_resignable_artifacts(self):
        with tempfile.TemporaryDirectory(prefix="native-manifest-") as temp:
            folder = pathlib.Path(temp) / "release"
            folder.mkdir()
            self.fixture(folder)
            self.run_manifest(folder)
            result = json.loads((folder / "build-manifest.json").read_text("utf-8"))
            self.assertEqual(len(result["artifacts"]), 2)
            self.assertEqual(result["runner_compat_shim"]["decision"], "not-required-no-reference")
            self.assertEqual(result["validation"]["device_validation"], "pending")
            self.assertEqual(result["validation"]["continuous_drag_checks_passed"], 189)
            self.assertEqual(result["validation"]["swift_policy_test_count"], 29)
            for artifact in result["artifacts"]:
                self.assertEqual(artifact["sha256"], hashlib.sha256((folder / artifact["name"]).read_bytes()).hexdigest())
                self.assertTrue(artifact["requires_resigning"])
                self.assertEqual(artifact["provisioning_profiles"], 0)

    def test_profile_presence_aborts_before_manifest(self):
        with tempfile.TemporaryDirectory(prefix="native-manifest-") as temp:
            folder = pathlib.Path(temp) / "release"
            folder.mkdir()
            self.fixture(folder, profile=True)
            with self.assertRaisesRegex(SystemExit, "provisioning profile"):
                self.run_manifest(folder)
            self.assertFalse((folder / "build-manifest.json").exists())

    def test_missing_path_check_result_aborts_before_manifest(self):
        with tempfile.TemporaryDirectory(prefix="native-manifest-") as temp:
            folder = pathlib.Path(temp) / "release"
            folder.mkdir()
            self.fixture(folder)
            (folder.parent / "build" / "continuous-drag-tests.log").unlink()
            with self.assertRaisesRegex(SystemExit, "Continuous drag test result"):
                self.run_manifest(folder)
            self.assertFalse((folder / "build-manifest.json").exists())

    def test_failed_policy_suite_cannot_be_reported_as_passed(self):
        with tempfile.TemporaryDirectory(prefix="native-manifest-") as temp:
            folder = pathlib.Path(temp) / "release"
            folder.mkdir()
            self.fixture(folder)
            (folder.parent / "build" / "swift-policy-tests.log").write_text(
                "Executed 7 tests, with 0 failures\nExecuted 29 tests, with 1 failure\n", encoding="utf-8")
            with self.assertRaisesRegex(SystemExit, "Swift policy test result"):
                self.run_manifest(folder)
            self.assertFalse((folder / "build-manifest.json").exists())

if __name__ == "__main__": unittest.main()
