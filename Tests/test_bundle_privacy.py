import importlib.util
from pathlib import Path
import tempfile
import unittest


script = Path(__file__).resolve().parents[1] / "scripts" / "check-bundle-privacy.py"
spec = importlib.util.spec_from_file_location("bundle_privacy", script)
privacy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(privacy)


class BundlePrivacyTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="broschy-bundle-test-")
        self.addCleanup(self.temporary.cleanup)
        self.bundle = Path(self.temporary.name) / "Broschy.app"
        for name in privacy.EXPECTED_FILES:
            path = self.bundle / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"Declared fixture content\n")

    def test_declared_payload_passes(self):
        self.assertEqual(privacy.check_bundle(self.bundle), [])

    def test_binary_string_table_paths_are_detected_without_printing_them(self):
        binary = self.bundle / "Contents/MacOS/Broschy"
        for root in ["/Users/", "/home/", "/private/var/folders/", "/var/folders/", "/tmp/"]:
            with self.subTest(root=root):
                marker = root + "fixture-account/private-project/App.swift"
                binary.write_bytes(b"\xcf\xfa\xed\xfe\x00\x01" + marker.encode() + b"\x00\xff")
                errors = privacy.check_bundle(self.bundle)
                self.assertTrue(errors)
                self.assertNotIn("fixture-account", " ".join(errors))
                self.assertNotIn("private-project", " ".join(errors))

    def test_undeclared_local_data_and_symlinks_fail(self):
        extra = self.bundle / "Contents/Resources/local-private-settings.json"
        extra.write_text("{}")
        errors = privacy.check_bundle(self.bundle)
        self.assertTrue(errors)
        self.assertNotIn(extra.name, " ".join(errors))
        extra.unlink()
        link = self.bundle / "Contents/Resources/AppIcon.png"
        link.unlink()
        link.symlink_to(script)
        self.assertTrue(privacy.check_bundle(self.bundle))

    def test_missing_payload_fails(self):
        (self.bundle / "Contents/MacOS/broschy-cli").unlink()
        self.assertTrue(privacy.check_bundle(self.bundle))

    def test_credentials_fail_without_echoing_values(self):
        # Synthetic fragments are assembled here so test data is not mistaken
        # for a credential by source-history secret scanners.
        fake = "gh" + "p_" + "0" * 40
        (self.bundle / "Contents/Resources/Integrations/Guide.md").write_text(fake)
        errors = privacy.check_bundle(self.bundle)
        self.assertTrue(errors)
        self.assertNotIn(fake, " ".join(errors))

    def test_generic_user_instructions_and_system_sdk_paths_pass(self):
        text = b"~/Library/Application Support/NotchFlow\n/System/Library/Frameworks/AppKit.framework\n/usr/lib/libSystem.B.dylib"
        (self.bundle / "Contents/Resources/Integrations/Guide.md").write_bytes(text)
        self.assertEqual(privacy.check_bundle(self.bundle), [])


if __name__ == "__main__":
    unittest.main()
