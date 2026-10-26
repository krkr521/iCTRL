"""Packaging privacy/manifest regression checks; no real Apple artifacts or identity."""
import contextlib, hashlib, io, json, pathlib, plistlib, runpy, sys, tempfile, unittest, zipfile
from unittest.mock import patch

SCRIPT = pathlib.Path(__file__).with_name("native-build-manifest.py")

class NativeBuildManifestTests(unittest.TestCase):
    def fixture(self, folder, profile=False):
        (folder.parent / "build").mkdir(exist_ok=True)
        (folder.parent / "build" / "native-compat-status.txt").write_text("not-required-no-reference\n", encoding="utf-8")
        for name, app in [("iCTRL.ipa", "iCTRL"), ("iCTRLUITests-Runner.ipa", "iCTRLUITests-Runner")]:
            with zipfile.ZipFile(folder / name, "w") as archive:
                archive.writestr(f"Payload/{app}.app/Info.plist", plistlib.dumps({"CFBundleIdentifier": "test." + app}))
                if profile: archive.writestr(f"Payload/{app}.app/embedded.mobileprovision", b"must-not-be-read")

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

if __name__ == "__main__": unittest.main()
