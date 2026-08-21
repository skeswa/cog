import { defineConfig } from "vitepress";
import { renderMermaidDiagrams } from "./mermaid-markdown.mjs";
import { nav, sidebar } from "./navigation.mjs";

/**
 * The site is published under `skeswa.github.io/cog/`, sharing that one
 * GitHub Pages deployment with the DocC API reference. `base` therefore has to
 * agree with the `--hosting-base-path cog` the DocC archive is built with
 * (`mise run docs:api`); the two halves are merged into a single artifact by
 * `tools/assemble-docs-site.mjs`.
 *
 * Both values are overridable so the assembled site can be served from a
 * scratch directory at a different prefix while checking it locally.
 */
const base = process.env.VITEPRESS_BASE ?? "/cog/";
const siteUrl = process.env.VITEPRESS_SITE_URL ?? "https://skeswa.github.io/cog/";

export default defineConfig({
  lang: "en-US",
  title: "Cog",
  titleTemplate: ":title · Cog",
  description:
    "Cog is a fine-grained state-management project for native mobile UI: a Swift library for SwiftUI and a Kotlin library for Jetpack Compose.",
  base,
  cleanUrls: true,
  lastUpdated: true,

  // These two files are browsed directly on GitHub as often as they are read
  // here, so they stay named `README.md` in the tree and become directory
  // indexes only on the site.
  rewrites: {
    "swift/README.md": "swift/index.md",
    "kotlin/README.md": "kotlin/index.md",
  },

  // Scoped to the DocC half of the site and nothing else. Those routes are
  // real, but they are produced by `mise run docs:api` and only join this
  // output when `tools/assemble-docs-site.mjs` merges the two — VitePress
  // cannot see them at build time and would call every one of them dead. The
  // check stays on everywhere else, because a genuinely broken cross-document
  // link is exactly the failure this site exists to catch. The merge script
  // asserts these routes actually arrived.
  ignoreDeadLinks: [/^\/documentation\//],

  markdown: {
    config: renderMermaidDiagrams,
  },

  sitemap: { hostname: siteUrl },

  head: [
    ["meta", { property: "og:type", content: "website" }],
    ["meta", { property: "og:site_name", content: "Cog" }],
  ],

  themeConfig: {
    siteTitle: "Cog",
    nav,
    sidebar,
    outline: { level: [2, 3] },
    search: { provider: "local" },
    editLink: {
      pattern: "https://github.com/skeswa/cog/edit/main/docs/:path",
      text: "Edit this page on GitHub",
    },
    socialLinks: [{ icon: "github", link: "https://github.com/skeswa/cog" }],
    footer: {
      message: "Released under the MIT License.",
      copyright: "Copyright © 2026 Sandile Keswa",
    },
    lastUpdated: { text: "Last updated", formatOptions: { dateStyle: "medium" } },
  },
});
