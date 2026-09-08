import hashlib
import json
import pathlib
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
OFFICIAL_GPL_SHA256 = "3972dc9744f6499f0f9b2dbf76696f2ae7ad8af9b23dde66d6af86c9dfb36986"


class LicensePolicyTests(unittest.TestCase):
    def test_root_license_is_unmodified_official_gplv3_text(self) -> None:
        license_bytes = (REPO_ROOT / "LICENSE").read_bytes()
        self.assertEqual(hashlib.sha256(license_bytes).hexdigest(), OFFICIAL_GPL_SHA256)
        self.assertIn(b"Version 3, 29 June 2007", license_bytes)

    def test_all_official_plugin_manifests_declare_gpl3_only(self) -> None:
        manifests = sorted((REPO_ROOT / "Plugins").glob("*/plugin.json"))
        self.assertTrue(manifests)

        incorrect = []
        for manifest in manifests:
            document = json.loads(manifest.read_text(encoding="utf-8"))
            license_id = (document.get("presentation") or {}).get("license")
            if license_id != "GPL-3.0-only":
                incorrect.append(f"{manifest.parent.name}: {license_id!r}")

        self.assertEqual(incorrect, [])

    def test_third_party_notice_products_reference_existing_plugins(self) -> None:
        plugin_ids = {
            json.loads(manifest.read_text(encoding="utf-8"))["id"]
            for manifest in (REPO_ROOT / "Plugins").glob("*/plugin.json")
        }
        notice_manifest = json.loads(
            (
                REPO_ROOT
                / "Sources/Resources/ThirdPartyNotices/manifest.json"
            ).read_text(encoding="utf-8")
        )

        unknown_products = []
        for component in notice_manifest["components"]:
            for product in component["products"]:
                if product == "app":
                    continue
                plugin_id = product.removeprefix("plugin:")
                if plugin_id not in plugin_ids:
                    unknown_products.append(f"{component['id']}: {product}")

        self.assertEqual(unknown_products, [])

    def test_icon_source_provenance_matches_legal_inventory(self) -> None:
        icon_sources = json.loads(
            (
                REPO_ROOT / "docs/icon-gallery/sources/manifest.json"
            ).read_text(encoding="utf-8")
        )["sources"]
        notice_components = {
            component["id"]: component
            for component in json.loads(
                (
                    REPO_ROOT
                    / "Sources/Resources/ThirdPartyNotices/manifest.json"
                ).read_text(encoding="utf-8")
            )["components"]
        }

        for source in icon_sources:
            component = notice_components[source["id"]]
            self.assertEqual(component["repository"], source["repository"])
            self.assertEqual(component["revision"], source["revision"])
            self.assertEqual(component["license"], source["license"])

    def test_historical_apache_license_is_retained_outside_root_default(self) -> None:
        historical_license = REPO_ROOT / "LICENSES/Apache-2.0.txt"
        self.assertTrue(historical_license.is_file())
        self.assertIn(
            "Apache License\n                           Version 2.0",
            historical_license.read_text(encoding="utf-8"),
        )

    def test_project_license_surfaces_do_not_claim_apache_default(self) -> None:
        surfaces = {
            REPO_ROOT / "README.md": "GPL-3.0-only",
            REPO_ROOT / "README.zh-CN.md": "GPL-3.0-only",
            REPO_ROOT / "site/src/pages/index.astro": (
                "https://github.com/ggbond268/MacTools/blob/main/LICENSE"
            ),
            REPO_ROOT / "site/src/components/SiteFooter.astro": "GPL-3.0-only",
        }
        for surface, expected_license_reference in surfaces.items():
            content = surface.read_text(encoding="utf-8")
            self.assertIn(expected_license_reference, content, str(surface))
            self.assertNotIn("Apache License 2.0](LICENSE)", content, str(surface))


if __name__ == "__main__":
    unittest.main()
