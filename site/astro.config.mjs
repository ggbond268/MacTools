import { defineConfig } from "astro/config";

export default defineConfig({
  site: "https://mactools.ggbond.app",
  base: "/",
  output: "static",
  trailingSlash: "ignore",
});
