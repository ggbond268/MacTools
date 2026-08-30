import json
import os
import pathlib
import re
import subprocess
import tempfile
import unittest
from typing import Optional


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
SYNC_SCRIPT = REPO_ROOT / "scripts/plugins/sync-debug-plugins.sh"


def write_manifest(source: pathlib.Path, plugin_id: str, bundle_relative_path: str) -> None:
    (source / "plugin.json").write_text(
        json.dumps(
            {
                "id": plugin_id,
                "displayName": "Example",
                "version": "1.0.0",
                "minHostVersion": "99.0.0",
                "pluginKitVersion": 3,
                "bundleRelativePath": bundle_relative_path,
                "capabilities": {
                    "primaryPanel": False,
                    "componentPanel": False,
                    "configuration": False,
                },
                "permissions": [],
            }
        ),
        encoding="utf-8",
    )


def run_sync(
    root: pathlib.Path,
    plugin_id: str,
    bundle_relative_path: str,
) -> subprocess.CompletedProcess:
    source = root / "Source"
    products = root / "Products"
    output = root / "Output"
    install = root / "Install/Installed"
    bundle = products / "Example.bundle"
    source.mkdir()
    bundle.mkdir(parents=True)
    (bundle / "payload").write_text("debug bundle", encoding="utf-8")
    write_manifest(source, plugin_id, bundle_relative_path)

    return subprocess.run(
        [
            str(SYNC_SCRIPT),
            "--source-dir", str(source),
            "--products-dir", str(products),
            "--output-dir", str(output),
            "--install-dir", str(install),
        ],
        capture_output=True,
        text=True,
    )


def mutation_targets(
    root: pathlib.Path,
    plugin_id: str,
    bundle_relative_path: str,
) -> list[pathlib.Path]:
    """The exact paths the script's mutations would touch for these manifest
    values if validation were bypassed, normalized the way the OS resolves
    `..` and `.` components during a real filesystem operation."""
    output = root / "Output"
    install = root / "Install/Installed"
    safe_name = re.sub(r"[^A-Za-z0-9._-]", "_", plugin_id)

    package_path = str(output / "Packages" / f"{plugin_id}.mactoolsplugin")
    install_path = str(install / f"{plugin_id}.mactoolsplugin")
    # The script builds the bundle destination by string concatenation
    # ("$package_path/$bundle_relative_path"), so mirror that rather than
    # pathlib's absolute-RHS replacement semantics.
    bundle_destination = f"{package_path}/{bundle_relative_path}"
    state_path = str(output / ".sync-state" / f"{safe_name}.sha256")

    return [
        pathlib.Path(os.path.normpath(path))
        for path in (package_path, install_path, bundle_destination, state_path)
    ]


def place_sentinels(root: pathlib.Path, targets: list[pathlib.Path]) -> list[pathlib.Path]:
    """Drop a sentinel file at each target path. Shallowest first, and a target
    nested inside an already-guarded one is skipped since the outer sentinel
    would already catch any rm/mkdir/mv at that location."""
    placed: list[pathlib.Path] = []
    for target in sorted(targets, key=lambda path: len(path.parts)):
        if any(
            str(target) == str(guarded) or str(target).startswith(str(guarded) + os.sep)
            for guarded in placed
        ):
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text("sentinel", encoding="utf-8")
        placed.append(target)
    return placed


def tree_snapshot(root: pathlib.Path) -> dict[str, tuple[str, Optional[str]]]:
    """Every relative path under root with its type and file content, so an
    unchanged snapshot proves the script created, deleted, or modified nothing."""
    snapshot: dict[str, tuple[str, str | None]] = {}
    for path in sorted(root.rglob("*")):
        relative = path.relative_to(root).as_posix()
        if path.is_symlink():
            snapshot[relative] = ("symlink", os.readlink(path))
        elif path.is_dir():
            snapshot[relative] = ("dir", None)
        else:
            snapshot[relative] = ("file", path.read_text(encoding="utf-8"))
    return snapshot


class MaliciousManifestValidationTests(unittest.TestCase):
    def assert_rejected_without_mutation(
        self,
        root: pathlib.Path,
        plugin_id: str,
        bundle_relative_path: str,
        expected_error: str,
    ) -> None:
        source = root / "Source"
        products = root / "Products"
        source.mkdir()
        (products / "Example.bundle").mkdir(parents=True)
        (products / "Example.bundle" / "payload").write_text(
            "debug bundle", encoding="utf-8"
        )
        write_manifest(source, plugin_id, bundle_relative_path)

        # Sentinels sit exactly where the unsafe values would land if the
        # validation were bypassed (e.g. Output/evil.mactoolsplugin for the
        # id "../evil", Output/escape.bundle for "../../escape.bundle").
        place_sentinels(root, mutation_targets(root, plugin_id, bundle_relative_path))
        before = tree_snapshot(root)

        result = subprocess.run(
            [
                str(SYNC_SCRIPT),
                "--source-dir", str(source),
                "--products-dir", str(products),
                "--output-dir", str(root / "Output"),
                "--install-dir", str(root / "Install/Installed"),
            ],
            capture_output=True,
            text=True,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn(expected_error, result.stderr)
        # Discovery validates the manifest before any OUTPUT_DIR/Packages/state/
        # install directory is created, so the whole temp tree must be untouched.
        self.assertEqual(tree_snapshot(root), before)

    def test_malicious_id_with_path_traversal_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            self.assert_rejected_without_mutation(
                pathlib.Path(temporary_directory),
                "../evil",
                "Example.bundle",
                "Invalid plugin id",
            )

    def test_reserved_marketplace_id_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            self.assert_rejected_without_mutation(
                pathlib.Path(temporary_directory),
                "marketplace",
                "Example.bundle",
                "Invalid plugin id",
            )

    def test_id_outside_manifest_grammar_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            self.assert_rejected_without_mutation(
                pathlib.Path(temporary_directory),
                "a/b",
                "Example.bundle",
                "Invalid plugin id",
            )

    def test_bundle_path_with_dot_dot_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            self.assert_rejected_without_mutation(
                pathlib.Path(temporary_directory),
                "example-debug-plugin",
                "../../escape.bundle",
                "Invalid bundleRelativePath",
            )

    def test_absolute_bundle_path_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            self.assert_rejected_without_mutation(
                pathlib.Path(temporary_directory),
                "example-debug-plugin",
                "/etc/escape.bundle",
                "Invalid bundleRelativePath",
            )

    def test_bundle_path_with_dot_component_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            self.assert_rejected_without_mutation(
                pathlib.Path(temporary_directory),
                "example-debug-plugin",
                "Sub/./escape.bundle",
                "Invalid bundleRelativePath",
            )

    def test_bundle_path_with_empty_component_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            self.assert_rejected_without_mutation(
                pathlib.Path(temporary_directory),
                "example-debug-plugin",
                "Sub//escape.bundle",
                "Invalid bundleRelativePath",
            )

    def test_valid_manifest_still_syncs(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            result = run_sync(
                pathlib.Path(temporary_directory),
                "example-debug-plugin",
                "Example.bundle",
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("Synced 1 changed", result.stdout)


class SymlinkEscapeTests(unittest.TestCase):
    def setup_valid_sync(
        self,
        root: pathlib.Path,
        bundle_relative_path: str = "Example.bundle",
    ) -> None:
        """Create the source manifest and built bundle the sync would consume."""
        source = root / "Source"
        products = root / "Products"
        bundle = products / "Example.bundle"
        source.mkdir()
        bundle.mkdir(parents=True)
        (bundle / "payload").write_text("debug bundle", encoding="utf-8")
        write_manifest(source, "example-debug-plugin", bundle_relative_path)

    def run_valid_sync(
        self,
        root: pathlib.Path,
    ) -> subprocess.CompletedProcess:
        return subprocess.run(
            [
                str(SYNC_SCRIPT),
                "--source-dir", str(root / "Source"),
                "--products-dir", str(root / "Products"),
                "--output-dir", str(root / "Output"),
                "--install-dir", str(root / "Install/Installed"),
            ],
            capture_output=True,
            text=True,
        )

    def assert_rejected_with_untouched_tree(
        self,
        root: pathlib.Path,
        result: subprocess.CompletedProcess,
        before: dict[str, tuple[str, Optional[str]]],
    ) -> None:
        """The preflight phase resolves and validates every destination before
        any directory creation or file change, so a rejected run must leave the
        whole temporary tree byte-for-byte identical: no Output/Packages/
        .sync-state/install directories, no rebuilt package, no fingerprint."""
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Refusing to operate outside", result.stderr)
        self.assertEqual(tree_snapshot(root), before)

    def test_symlinked_packages_dir_cannot_redirect_package_writes(self) -> None:
        """A pre-existing Output/Packages symlink must not let package_path
        escape OUTPUT_DIR: the preflight refuses before creating Output,
        .sync-state, or the install store."""
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = pathlib.Path(temporary_directory)
            output = root / "Output"
            external = root / "ExternalPackages"
            output.mkdir()
            external.mkdir()
            sentinel = external / "precious.bundle"
            sentinel.write_text("precious", encoding="utf-8")
            (output / "Packages").symlink_to(external, target_is_directory=True)
            self.setup_valid_sync(root)
            before = tree_snapshot(root)

            result = self.run_valid_sync(root)

            self.assertEqual(sentinel.read_text(encoding="utf-8"), "precious")
            self.assert_rejected_with_untouched_tree(root, result, before)

    def test_symlinked_bundle_subdir_cannot_redirect_bundle_writes(self) -> None:
        """A pre-existing symlink inside the package path must not let the
        bundle destination escape OUTPUT_DIR: the preflight refuses before
        anything is built."""
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = pathlib.Path(temporary_directory)
            output = root / "Output"
            package = output / "Packages/example-debug-plugin.mactoolsplugin"
            external = root / "ExternalBundle"
            output.mkdir(parents=True)
            package.mkdir(parents=True)
            external.mkdir()
            sentinel = external / "Example.bundle"
            sentinel.write_text("precious", encoding="utf-8")
            (package / "Sub").symlink_to(external, target_is_directory=True)
            self.setup_valid_sync(root, bundle_relative_path="Sub/Example.bundle")
            before = tree_snapshot(root)

            result = self.run_valid_sync(root)

            self.assertEqual(sentinel.read_text(encoding="utf-8"), "precious")
            self.assert_rejected_with_untouched_tree(root, result, before)

    def test_symlinked_install_destination_cannot_redirect_installs(self) -> None:
        """A pre-existing symlink at the installed package path must not let
        ditto/mv write outside the install root: the preflight refuses before
        the output package is rebuilt or its fingerprint is written."""
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = pathlib.Path(temporary_directory)
            install = root / "Install/Installed"
            external = root / "ExternalInstall"
            install.mkdir(parents=True)
            external.mkdir()
            sentinel = external / "precious.bundle"
            sentinel.write_text("precious", encoding="utf-8")
            (install / "example-debug-plugin.mactoolsplugin").symlink_to(
                external, target_is_directory=True
            )
            self.setup_valid_sync(root)
            before = tree_snapshot(root)

            result = self.run_valid_sync(root)

            self.assertEqual(sentinel.read_text(encoding="utf-8"), "precious")
            self.assert_rejected_with_untouched_tree(root, result, before)

if __name__ == "__main__":
    unittest.main()
