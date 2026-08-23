import os
import pathlib
import plistlib
import shutil
import subprocess
import tempfile
import threading
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPT = REPO_ROOT / "scripts/install-debug-app.sh"
DEFAULT_BUNDLE_IDENTIFIER = "com.example.mactools-test"


class InstallDebugAppTests(unittest.TestCase):
    def start_signed_sleep_at_path(
        self,
        command_path: pathlib.Path,
    ) -> subprocess.Popen[bytes]:
        # Re-sign the copied platform binary before execution. Running the
        # unsigned copy can invoke Gatekeeper and make this CLI test interactive.
        shutil.copyfile("/bin/sleep", command_path)
        command_path.chmod(0o755)
        subprocess.run(
            ["/usr/bin/codesign", "--force", "--sign", "-", str(command_path)],
            check=True,
            capture_output=True,
        )
        return subprocess.Popen(
            [str(command_path), "30"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )

    def start_signed_sleep_app(
        self,
        app_path: pathlib.Path,
    ) -> subprocess.Popen[bytes]:
        # An executable whose path is inside an incomplete `.app` is assessed as
        # an application by macOS even when the executable itself is signed. Build
        # and sign the complete fixture bundle so the CLI test cannot leave a
        # Gatekeeper "damaged app" dialog behind.
        self.make_app(app_path, "running")
        executable_name = "MacTools Test"
        executable = app_path / "Contents/MacOS" / executable_name
        subprocess.run(
            ["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app_path)],
            check=True,
            capture_output=True,
        )
        return subprocess.Popen(
            [str(executable), "30"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )

    def make_app(
        self,
        path: pathlib.Path,
        marker: str,
        *,
        bundle_identifier: str = DEFAULT_BUNDLE_IDENTIFIER,
        executable_name: str = "MacTools Test",
    ) -> None:
        executable = path / "Contents/MacOS" / executable_name
        executable.parent.mkdir(parents=True)
        shutil.copyfile("/bin/sleep", executable)
        executable.chmod(0o755)
        with (path / "Contents/Info.plist").open("wb") as handle:
            plistlib.dump(
                {
                    "CFBundleIdentifier": bundle_identifier,
                    "CFBundleExecutable": executable_name,
                },
                handle,
            )
        marker_path = path / "Contents/Resources/marker.txt"
        marker_path.parent.mkdir(parents=True)
        marker_path.write_text(marker, encoding="utf-8")
        subprocess.run(
            [
                "/usr/bin/codesign",
                "--force",
                "--sign",
                "-",
                "--identifier",
                bundle_identifier,
                "--requirements",
                f'=designated => identifier "{bundle_identifier}"',
                str(path),
            ],
            check=True,
            capture_output=True,
        )

    def test_term_after_backup_restores_previous_app(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = pathlib.Path(temporary_directory)
            source = root / "Built/MacTools Test.app"
            installed = root / "Home/Applications/MacTools Test.app"
            self.make_app(source, "new")
            self.make_app(installed, "previous")
            environment = os.environ.copy()
            environment["HOME"] = str(root / "Home")
            environment["MACTOOLS_LSREGISTER_PATH"] = "/usr/bin/true"
            environment["MACTOOLS_INSTALL_DEBUG_TEST_INTERRUPT_AFTER_BACKUP"] = "TERM"

            result = subprocess.run(
                [
                    str(SCRIPT),
                    str(source),
                    str(installed),
                    DEFAULT_BUNDLE_IDENTIFIER,
                ],
                env=environment,
                capture_output=True,
                text=True,
                check=False,
            )

            self.assertEqual(result.returncode, 143)
            self.assertEqual(
                (installed / "Contents/Resources/marker.txt").read_text(encoding="utf-8"),
                "previous",
            )
            self.assertFalse(
                list(installed.parent.glob(".mactools-debug-install.*")),
                "transaction staging directory should be cleaned after restoration",
            )

    def test_replacement_transaction_is_armed_before_backup_move(self) -> None:
        script = SCRIPT.read_text(encoding="utf-8")
        transaction = script.index('replacement_started=true\n    /bin/mv "$installed_app" "$backup_app"')
        interrupt_hook = script.index("MACTOOLS_INSTALL_DEBUG_TEST_INTERRUPT_AFTER_BACKUP")

        self.assertLess(transaction, interrupt_hook)

    def test_identity_mismatch_is_rejected_before_stopping_retained_app(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = pathlib.Path(temporary_directory)
            source = root / "Built/MacTools Test.app"
            installed = root / "Home/Applications/MacTools Test.app"
            self.make_app(
                source,
                "new",
                bundle_identifier="com.example.unrelated",
            )
            self.make_app(installed, "previous")
            environment = os.environ.copy()
            environment["HOME"] = str(root / "Home")
            environment["MACTOOLS_LSREGISTER_PATH"] = "/usr/bin/true"
            result = subprocess.run(
                [
                    str(SCRIPT),
                    str(source),
                    str(installed),
                    "com.example.unrelated",
                ],
                env=environment,
                capture_output=True,
                text=True,
                check=False,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("identity does not match", result.stderr)
            self.assertEqual(
                (installed / "Contents/Resources/marker.txt").read_text(encoding="utf-8"),
                "previous",
            )
            self.assertFalse(list(installed.parent.glob(".mactools-debug-install.*")))

            # Verify the stop step remains unreachable until identity validation
            # succeeds without launching the intentionally mismatched app bundle.
            script = SCRIPT.read_text(encoding="utf-8")
            identity_check = script.index(
                'retained_bundle_identifier="$(read_bundle_value'
            )
            process_stop = script.index('installed_executable="$installed_app/Contents/MacOS/')
            self.assertLess(identity_check, process_stop)

    def test_configured_bundle_identifier_mismatch_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = pathlib.Path(temporary_directory)
            source = root / "Built/MacTools Test.app"
            installed = root / "Home/Applications/MacTools Test.app"
            self.make_app(source, "new")
            environment = os.environ.copy()
            environment["HOME"] = str(root / "Home")
            environment["MACTOOLS_LSREGISTER_PATH"] = "/usr/bin/true"

            result = subprocess.run(
                [
                    str(SCRIPT),
                    str(source),
                    str(installed),
                    "com.example.different.mactools.dev",
                ],
                env=environment,
                capture_output=True,
                text=True,
                check=False,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("does not match configured identity", result.stderr)
            self.assertFalse(installed.exists())

    def test_unregisters_other_apps_with_the_same_debug_name(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = pathlib.Path(temporary_directory)
            source = root / "Built/MacTools Test.app"
            installed = root / "Home/Applications/MacTools Test.app"
            stale = root / "OldBuild/MacTools Test.app"
            registrar = root / "fake-lsregister"
            registrar_log = root / "lsregister.log"
            self.make_app(source, "new")
            registrar.write_text(
                """#!/bin/zsh
if [[ \"$1\" == \"-dump\" ]]; then
    print -r -- '----------------------------------------'
    print -r -- 'path: __STALE_PATH__'
    print -r -- 'name: MacTools Test'
    print -r -- 'identifier: com.example.old-debug'
    print -r -- '----------------------------------------'
    print -r -- 'path: __KEEP_PATH__'
    print -r -- 'name: MacTools Test'
    print -r -- 'identifier: com.example.mactools-test'
    print -r -- '----------------------------------------'
    exit 0
fi
print -r -- \"$@\" >>\"$MACTOOLS_LSREGISTER_LOG\"
""".replace("__STALE_PATH__", str(stale)).replace("__KEEP_PATH__", str(installed)),
                encoding="utf-8",
            )
            registrar.chmod(0o755)
            environment = os.environ.copy()
            environment["HOME"] = str(root / "Home")
            environment["MACTOOLS_LSREGISTER_PATH"] = str(registrar)
            environment["MACTOOLS_LSREGISTER_LOG"] = str(registrar_log)

            result = subprocess.run(
                [
                    str(SCRIPT),
                    str(source),
                    str(installed),
                    DEFAULT_BUNDLE_IDENTIFIER,
                ],
                env=environment,
                capture_output=True,
                text=True,
                check=False,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            registrations = registrar_log.read_text(encoding="utf-8").splitlines()
            self.assertIn(f"-u {stale.resolve()}", registrations)
            self.assertIn(f"-u {source.resolve()}", registrations)
            self.assertIn(f"-f {installed.resolve()}", registrations)
            self.assertNotIn(f"-u {installed.resolve()}", registrations)

    def test_stop_debug_app_targets_exact_installed_executable_path(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = pathlib.Path(temporary_directory)
            installed_executable = (
                root / "Applications/MacTools Test.app/Contents/MacOS/MacTools Test"
            )
            decoy_executable = root / "decoy/MacTools Test"
            decoy_executable.parent.mkdir(parents=True)
            installed_process = self.start_signed_sleep_app(
                root / "Applications/MacTools Test.app"
            )
            decoy_process = self.start_signed_sleep_at_path(decoy_executable)
            installed_waiter = threading.Thread(target=installed_process.wait, daemon=True)
            installed_waiter.start()
            try:
                result = subprocess.run(
                    [
                        "/usr/bin/make",
                        "-f",
                        str(REPO_ROOT / "Makefile"),
                        "stop-debug-app",
                        "APP_PRODUCT_NAME=MacTools Test",
                        f"LOCAL_APP_INSTALL_DIR={root / 'Applications'}",
                    ],
                    cwd=REPO_ROOT,
                    capture_output=True,
                    text=True,
                    check=False,
                )

                self.assertEqual(result.returncode, 0, result.stderr)
                installed_waiter.join(timeout=5)
                self.assertIsNotNone(installed_process.poll())
                self.assertIsNone(
                    decoy_process.poll(),
                    "a same-basename process outside the retained app must survive",
                )
            finally:
                for process in (installed_process, decoy_process):
                    if process.poll() is None:
                        process.terminate()
                        process.wait(timeout=5)


if __name__ == "__main__":
    unittest.main()
