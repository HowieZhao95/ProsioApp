import importlib.util
import plistlib
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


MODULE_PATH = Path(__file__).with_name("check.py")
SPEC = importlib.util.spec_from_file_location("recording_app_build_check", MODULE_PATH)
check = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(check)


class AppBuildCheckTests(unittest.TestCase):
    def test_non_dictionary_info_plist_is_rejected_cleanly(self):
        with tempfile.TemporaryDirectory() as directory:
            app = self.make_app(Path(directory), "Prosio.app", "com.example.Prosio")
            with (app / "Contents/Info.plist").open("wb") as stream:
                plistlib.dump(["invalid bundle metadata"], stream)
            with self.assertRaisesRegex(check.CheckError, "must contain a dictionary"):
                check.inspect_app(str(app))

    def make_app(self, root: Path, name: str, identifier: str) -> Path:
        app = root / name
        executable = app / "Contents/MacOS/Prosio"
        executable.parent.mkdir(parents=True)
        executable.write_bytes(b"test placeholder")
        with (app / "Contents/Info.plist").open("wb") as stream:
            plistlib.dump(
                {
                    "CFBundleIdentifier": identifier,
                    "CFBundleExecutable": "Prosio",
                    "CFBundleShortVersionString": "1.2.3",
                    "CFBundleVersion": "42",
                },
                stream,
            )
        return app

    def fake_cli(self, *, requirement="identifier \"com.example.Prosio\"", avkit=True):
        def run(*args):
            if "lipo" in args[0]:
                out = "arm64 x86_64\n"
            elif "dwarfdump" in args[0]:
                out = (
                    "UUID: 11111111-1111-1111-1111-111111111111 (arm64)\n"
                    "UUID: 22222222-2222-2222-2222-222222222222 (x86_64)\n"
                )
            elif "otool" in args[0]:
                selected_avkit = avkit.get(args[2], False) if isinstance(avkit, dict) else avkit
                dependency = (
                    "/System/Library/Frameworks/AVKit.framework/Versions/A/AVKit (compatibility version 1.0.0)\n"
                    if selected_avkit
                    else "/System/Library/PrivateFrameworks/_AVKit_SwiftUI.framework/Versions/A/_AVKit_SwiftUI (compatibility version 1.0.0)\n"
                )
                out = f"{args[-1]}:\n\t{dependency}"
            elif args[1:3] == ("-dr", "-"):
                out = ""
                selected_requirement = (
                    requirement["installed"] if isinstance(requirement, dict) and args[-1].endswith("Installed.app")
                    else requirement["build"] if isinstance(requirement, dict)
                    else requirement
                )
                return subprocess.CompletedProcess(args, 0, out, f"{args[-1]}: designated => {selected_requirement}\n")
            else:
                out = ""
            return subprocess.CompletedProcess(args, 0, out, "")

        return run

    def test_reports_each_architecture_uuid_and_requires_direct_avkit(self):
        with tempfile.TemporaryDirectory() as directory:
            app = self.make_app(Path(directory), "Prosio.app", "com.example.Prosio")
            with patch.object(check, "run", side_effect=self.fake_cli()):
                result = check.inspect_app(str(app))
        self.assertTrue(result["ok"])
        self.assertEqual(result["bundle_id"], "com.example.Prosio")
        self.assertEqual([a["architecture"] for a in result["architectures"]], ["arm64", "x86_64"])
        self.assertEqual(result["architectures"][1]["uuid"], "22222222-2222-2222-2222-222222222222")

    def test_private_avkit_swiftui_does_not_satisfy_avkit_dependency(self):
        with tempfile.TemporaryDirectory() as directory:
            app = self.make_app(Path(directory), "Prosio.app", "com.example.Prosio")
            with patch.object(check, "run", side_effect=self.fake_cli(avkit={"arm64": True, "x86_64": False})):
                with self.assertRaisesRegex(check.CheckError, "architecture x86_64 does not directly link AVKit.framework"):
                    check.inspect_app(str(app))

    def test_optional_reference_compares_designated_requirement(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app = self.make_app(root, "Build.app", "com.example.Prosio")
            installed = self.make_app(root, "Installed.app", "com.example.Prosio")
            with patch.object(check, "run", side_effect=self.fake_cli()):
                result = check.inspect_app(str(app), str(installed))
            self.assertTrue(result["identity_matches_reference"])

            with patch.object(
                check,
                "run",
                side_effect=self.fake_cli(
                    requirement={
                        "build": 'identifier "com.example.Prosio"',
                        "installed": 'identifier "com.other.App"',
                    }
                ),
            ):
                with self.assertRaisesRegex(check.CheckError, "designated requirement differs"):
                    check.inspect_app(str(app), str(installed))

    def test_system_cli_timeout_becomes_check_error(self):
        with patch.object(check.subprocess, "run", side_effect=subprocess.TimeoutExpired("otool", 30)):
            with self.assertRaisesRegex(check.CheckError, "otool timed out after 30 seconds"):
                check.run("/usr/bin/otool", "-L", "/tmp/Prosio")

    def test_executable_symlink_cannot_escape_macos_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app = self.make_app(root, "Prosio.app", "com.example.Prosio")
            executable = app / "Contents/MacOS/Prosio"
            external = root / "outside-bundle-executable"
            external.write_bytes(b"not an app executable")
            executable.unlink()
            executable.symlink_to(external)
            with self.assertRaisesRegex(check.CheckError, "resolves outside Contents/MacOS"):
                check.inspect_app(str(app))

    def test_code_signature_verification_failure_is_reported(self):
        with tempfile.TemporaryDirectory() as directory:
            app = self.make_app(Path(directory), "Prosio.app", "com.example.Prosio")
            normal_run = self.fake_cli()

            def fail_signature(*args):
                if args[1:4] == ("--verify", "--deep", "--strict"):
                    raise check.CheckError("codesign verification rejected bundle")
                return normal_run(*args)

            with patch.object(check, "run", side_effect=fail_signature):
                with self.assertRaisesRegex(check.CheckError, "codesign verification rejected bundle"):
                    check.inspect_app(str(app))

    def test_non_string_bundle_metadata_is_rejected_cleanly(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app = self.make_app(root, "Prosio.app", "com.example.Prosio")
            info_path = app / "Contents/Info.plist"
            with info_path.open("rb") as stream:
                info = plistlib.load(stream)
            info["CFBundleVersion"] = [42]
            with info_path.open("wb") as stream:
                plistlib.dump(info, stream)
            with self.assertRaisesRegex(check.CheckError, "CFBundleVersion must be a string"):
                check.inspect_app(str(app))


if __name__ == "__main__":
    unittest.main()
