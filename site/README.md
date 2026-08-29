# MacTools website

The Astro website consumes checked-in data generated from `Plugins/*/plugin.json`; it never fetches the production plugin catalog during a build.

After changing a plugin manifest or a referenced Marketplace asset, run:

```bash
npm run generate:plugins
npm run check:generated-plugins
npm run build
```

The generated JSON in `src/generated/` and checksum-named assets in `public/generated/plugin-assets/` are committed. CI rejects stale output.
