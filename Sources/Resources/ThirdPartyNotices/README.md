# Third-Party Notices

[`manifest.json`](manifest.json) is the canonical inventory of third-party dependencies, adapted implementations, and assets that are included in MacTools release artifacts. Each entry pins an upstream revision, records its reviewed GPLv3 compatibility, identifies its relationship to MacTools, lists the affected products and source paths, and points to the retained upstream license text.

Application and plugin builds generate product-specific `THIRD_PARTY_NOTICES.txt` files from this inventory. A release artifact receives only the entries that apply to that artifact. Do not edit generated notice files by hand.

Research-only projects are not distribution components and do not belong in this manifest. A project should be added only when its code, adapted expression, dependency, or asset is present in a release artifact. Preserve existing source-level copyright and license notices in addition to this central inventory.

The menu-bar icon source mapping remains in [`docs/icon-gallery/sources/manifest.json`](../../../docs/icon-gallery/sources/manifest.json); its revisions and license identifiers must match this legal inventory.
