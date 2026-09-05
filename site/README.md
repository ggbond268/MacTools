# MacTools website

The Astro website consumes checked-in data generated from `Plugins/*/plugin.json` and the repository-local `Localizable.xcstrings` files referenced by those manifests; it never fetches the production plugin catalog during a build.

After changing a plugin manifest, a referenced localization string, or a Marketplace asset, run:

```bash
npm run generate:plugins
npm run check:generated-plugins
npm run build
```

The generated JSON in `src/generated/` and checksum-named assets in `public/generated/plugin-assets/` are committed. CI rejects stale output.
