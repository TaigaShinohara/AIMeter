"""Distribution gates use synthetic bundles and mocked Apple/GitHub commands."""
import importlib.util
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location(
    "release", Path(__file__).resolve().parents[1] / "scripts/release.py"
)
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)
FINGERPRINT = "A" * 40
TEAM = "ABCDE12345"


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.app = self.root / "AIMeter.app"
        self.notes = self.root / "validation-notes.md"
        self.notes.write_text("Synthetic test only; no runtime verification.")

    def command(self, *args, **kwargs):
        if args[0] == "/usr/bin/lipo":
            return "arm64 x86_64\n"
        if args[0] == "/usr/bin/otool":
            return "binary:\n\t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0)\n"
        return ""

    def package(self):
        source = self.root / "source"
        resources = source / "Sources/AIMeter/Resources"
        resources.mkdir(parents=True)
        (resources / "AppIcon.icns").write_bytes(b"synthetic icon")
        (resources / "personal-log.json").write_text("MUST NOT SHIP")
        (source / "LICENSE").write_text("synthetic license")
        binaries = self.root / "binaries"
        binaries.mkdir()
        for name in ("AIMeter", "AIMeterWidgetExtension"):
            (binaries / name).write_bytes(b"synthetic executable")
        release.package_app(source, binaries, self.app, "1.1.1", "3", "b" * 40)

    @patch.object(release, "run")
    def test_bundle_is_allowlisted_and_versions_match(self, command):
        command.side_effect = self.command
        self.package()
        self.assertFalse(list(self.app.rglob("personal-log.json")))
        self.assertTrue((self.app / "Contents/Resources/LICENSE").exists())
        for bundle in release.bundles(self.app):
            info = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())
            self.assertEqual(info["CFBundleVersion"], "3")
            self.assertEqual(info["AIMeterSourceCommit"], "b" * 40)

    @patch.object(release, "run")
    def test_single_architecture_cannot_be_labeled_universal(self, command):
        command.side_effect = lambda *args, **kw: "arm64\n"
        with self.assertRaisesRegex(ValueError, "both contain"):
            self.package()

    @patch.object(release, "run")
    def test_build_machine_library_dependency_is_rejected(self, command):
        command.side_effect = lambda *args, **kw: (
            "arm64 x86_64" if args[0].endswith("lipo") else
            "binary:\n\t/opt/homebrew/lib/private.dylib (compatibility version 1)\n"
        )
        with self.assertRaisesRegex(ValueError, "Non-system"):
            self.package()

    @patch.object(release, "run")
    def test_rejects_wrong_certificate_type_and_team(self, command):
        for name in ("Apple Development", "Apple Distribution", "Developer ID Installer"):
            command.return_value = f'1) {FINGERPRINT} "{name}: Example ({TEAM})"'
            with self.assertRaisesRegex(ValueError, "identity not found"):
                release.check_identity(FINGERPRINT, TEAM)
        command.return_value = f'1) {FINGERPRINT} "Developer ID Application: Example (WRONG12345)"'
        with self.assertRaises(ValueError):
            release.check_identity(FINGERPRINT, TEAM)
        command.return_value = f'1) {FINGERPRINT} "Developer ID Application: Example ({TEAM})"'
        release.check_identity(FINGERPRINT, TEAM)

    @patch.object(release, "run")
    def test_ad_hoc_is_never_accepted(self, command):
        with self.assertRaises(ValueError):
            release.check_identity("-", TEAM)
        command.assert_not_called()

    @patch.object(release, "run")
    def test_missing_certificate_stops_before_build_metadata_or_submission(self, command):
        command.return_value = "0 valid identities found"
        with self.assertRaisesRegex(ValueError, "identity not found"):
            release.notarize(self.root, FINGERPRINT, TEAM, "synthetic-profile")
        self.assertEqual(command.call_count, 1)
        self.assertFalse((self.root / "release.json").exists())

    @patch.object(release, "check_identity")
    @patch.object(release, "verify_signature")
    @patch.object(release, "run")
    def test_rejected_notarization_never_creates_publishable_archive(self, command, signature, identity):
        command.side_effect = self.command
        self.package()
        release.write_json(self.root / "build.json",
                           {"version": "1.1.1", "build_number": "3", "commit": "b" * 40})

        def rejected(*args, **kwargs):
            if "notarytool" in args:
                return json.dumps({"status": "Invalid", "id": "synthetic-submission"})
            return self.command(*args, **kwargs)

        command.side_effect = rejected
        with self.assertRaisesRegex(ValueError, "not accepted"):
            release.notarize(self.root, FINGERPRINT, TEAM, "synthetic-profile")
        self.assertFalse((self.root / "release.json").exists())
        self.assertFalse(list(self.root.glob("AIMeter-*.zip")))
        self.assertFalse(any("stapler" in call.args for call in command.call_args_list))

    def receipt(self):
        archive = self.root / "AIMeter-1.1.1-macos-universal.zip"
        archive.write_bytes(b"synthetic archive")
        digest = release.sha256(archive)
        release.write_json(self.root / "release.json", {
            "archive": archive.name, "version": "1.1.1", "build_number": "3",
            "sha256": digest, "team": TEAM, "commit": "b" * 40,
        })
        (self.root / "SHA256SUMS").write_text(f"{digest}  {archive.name}\n")
        return archive

    @patch.object(release, "run")
    def test_archive_tampering_stops_before_upload_or_extraction(self, command):
        archive = self.receipt()
        archive.write_bytes(b"modified")
        with self.assertRaisesRegex(ValueError, "changed after"):
            release.publish(self.root, self.notes)
        command.assert_not_called()

    @patch.object(release, "run")
    def test_checksum_tampering_stops_before_upload(self, command):
        self.receipt()
        (self.root / "SHA256SUMS").write_text("wrong")
        with self.assertRaisesRegex(ValueError, "SHA256SUMS"):
            release.publish(self.root, self.notes)
        command.assert_not_called()

    @patch.object(release, "validate_release")
    @patch.object(release, "run")
    def test_unmerged_source_is_never_uploaded(self, command, validation):
        validation.return_value = {"version": "1.1.1", "commit": "b" * 40}

        def reject(*args, **kwargs):
            if "merge-base" in args:
                raise subprocess.CalledProcessError(1, args)
            return ""

        command.side_effect = reject
        with self.assertRaises(subprocess.CalledProcessError):
            release.publish(self.root, self.notes)
        self.assertFalse(any(call.args[0] == "gh" for call in command.call_args_list))

    @patch.object(release, "validate_release")
    @patch.object(release, "run")
    def test_failed_uploaded_digest_leaves_draft(self, command, validation):
        archive = self.receipt()
        validation.return_value = json.loads((self.root / "release.json").read_text())

        def mismatch(*args, **kwargs):
            if any("matching-refs" in str(arg) for arg in args):
                return "[]"
            if args[:2] == ("gh", "api"):
                return json.dumps({"assets": [{"name": archive.name, "digest": "sha256:wrong"}]})
            return ""

        command.side_effect = mismatch
        with self.assertRaisesRegex(ValueError, "remains a draft"):
            release.publish(self.root, self.notes)
        self.assertTrue(any(call.args[:3] == ("gh", "release", "create")
                            for call in command.call_args_list))
        self.assertFalse(any(call.args[:3] == ("gh", "release", "edit")
                             for call in command.call_args_list))

    @patch.object(release, "validate_release")
    @patch.object(release, "run")
    def test_existing_tag_is_not_overwritten(self, command, validation):
        validation.return_value = {"version": "1.1.1", "commit": "b" * 40}
        command.return_value = json.dumps([{"ref": "refs/tags/v1.1.1"}])
        with self.assertRaisesRegex(ValueError, "already exists"):
            release.publish(self.root, self.notes)
        self.assertFalse(any(call.args[:3] == ("gh", "release", "create")
                             for call in command.call_args_list))


if __name__ == "__main__":
    unittest.main()
