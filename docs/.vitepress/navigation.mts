import type { DefaultTheme } from "vitepress";

/**
 * The site's sidebars, written by hand rather than scanned from the
 * filesystem.
 *
 * The Swift order below is not alphabetical and must not become alphabetical:
 * it reproduces the numbered reading order in `docs/swift/README.md` under
 * "The documents", which is editorial. `docs/kotlin/README.md` carries the
 * same kind of list under "Start here". Those two files remain the source of
 * truth; this file mirrors them, and a document added there belongs here in
 * the same revision.
 *
 * Deriving labels from each file's first heading was the alternative, and it
 * is unsafe here: `docs/maintainers/ci.md` contains eight `#` shell comments
 * inside fenced code blocks that a line-based scanner reads as headings.
 *
 * Sidebars are keyed by path prefix so each section shows only its own
 * documents.
 */

const swiftSidebar: DefaultTheme.SidebarItem[] = [
  {
    text: "Cog for Swift",
    link: "/swift/",
    items: [
      { text: "Shared state model", link: "/design" },
      {
        text: "Design",
        items: [
          { text: "Core design", link: "/swift/design/exploration" },
          { text: "Mechanisms and background work", link: "/swift/design/mechanisms" },
          { text: "Rx operator map", link: "/swift/design/rx" },
          { text: "Data-oriented runtime", link: "/swift/design/perf" },
          { text: "Prior art and public names", link: "/swift/design/prior-art" },
          { text: "Lint tooling", link: "/swift/design/lint" },
        ],
      },
      {
        text: "Handbook",
        link: "/swift/guide/",
        items: [
          { text: "Structuring an app", link: "/swift/guide/app-structure" },
          { text: "Declaring state", link: "/swift/guide/declaring-state" },
          { text: "Reading state", link: "/swift/guide/reading-state" },
          { text: "Writing state", link: "/swift/guide/writing-state" },
          { text: "SwiftUI integration", link: "/swift/guide/swiftui" },
          { text: "Side effects", link: "/swift/guide/side-effects" },
          { text: "Navigation and deep linking", link: "/swift/guide/navigation" },
          { text: "Testing", link: "/swift/guide/testing" },
        ],
      },
      {
        text: "Implementation",
        items: [
          {
            text: "Architecture",
            link: "/swift/impl/architecture/",
            items: [
              { text: "State and graph", link: "/swift/impl/architecture/state-and-graph" },
              { text: "Turns", link: "/swift/impl/architecture/turns" },
              {
                text: "Boundaries and effects",
                link: "/swift/impl/architecture/boundaries-and-effects",
              },
              {
                text: "Async work and lifetime",
                link: "/swift/impl/architecture/async-and-lifetime",
              },
              {
                text: "Arena core internals",
                items: [
                  { text: "Core", link: "/swift/impl/architecture/arena-core" },
                  {
                    text: "Identity and caching",
                    link: "/swift/impl/architecture/arena-identity-and-caching",
                  },
                  { text: "Storage", link: "/swift/impl/architecture/arena-storage" },
                  { text: "Edges", link: "/swift/impl/architecture/arena-edges" },
                  { text: "Settlement", link: "/swift/impl/architecture/arena-settlement" },
                  {
                    text: "Specialization",
                    link: "/swift/impl/architecture/arena-specialization",
                  },
                ],
              },
              { text: "Codebase tour", link: "/swift/impl/architecture/codebase-tour" },
            ],
          },
          { text: "Test scenarios", link: "/swift/impl/scenarios" },
          { text: "Performance record", link: "/swift/impl/perf" },
          { text: "Performance history", link: "/swift/impl/perf-history" },
        ],
      },
      { text: "Design history", link: "/history" },
    ],
  },
];

const kotlinSidebar: DefaultTheme.SidebarItem[] = [
  {
    text: "Cog for Kotlin",
    link: "/kotlin/",
    items: [
      { text: "Shared state model", link: "/design" },
      { text: "Core design", link: "/kotlin/exploration" },
      { text: "Worked weather example", link: "/kotlin/example" },
      { text: "Flow map", link: "/kotlin/flows" },
      { text: "Effects and background work", link: "/kotlin/effects" },
      { text: "Performance model", link: "/kotlin/perf" },
      { text: "Design history", link: "/history" },
    ],
  },
];

const maintainersSidebar: DefaultTheme.SidebarItem[] = [
  {
    text: "Maintainers",
    items: [
      { text: "Change management", link: "/maintainers/changes" },
      { text: "CI and runner operations", link: "/maintainers/ci" },
      { text: "Releasing Cog for Swift", link: "/maintainers/releasing" },
    ],
  },
];

const sharedSidebar: DefaultTheme.SidebarItem[] = [
  {
    text: "Shared foundation",
    items: [
      { text: "Shared state model", link: "/design" },
      { text: "Design history", link: "/history" },
      { text: "Swift design", link: "/swift/" },
      { text: "Kotlin design", link: "/kotlin/" },
    ],
  },
];

export const sidebar: DefaultTheme.Sidebar = {
  "/swift/": swiftSidebar,
  "/kotlin/": kotlinSidebar,
  "/maintainers/": maintainersSidebar,
  "/design": sharedSidebar,
  "/history": sharedSidebar,
};

export const nav: DefaultTheme.NavItem[] = [
  { text: "Swift", link: "/swift/", activeMatch: "^/swift/" },
  { text: "Kotlin", link: "/kotlin/", activeMatch: "^/kotlin/" },
  {
    text: "API reference",
    // DocC, not VitePress. The archive is merged into this same site by
    // `tools/assemble-docs-site.mjs`, so the path is site-relative and
    // VitePress prefixes it with `base` — writing `/cog/…` here would produce
    // `/cog/cog/…`. `target: "_self"` is what makes the browser perform a real
    // navigation instead of handing the path to the client-side router, which
    // has no route for it.
    link: "/documentation/cog/",
    target: "_self",
    noIcon: true,
  },
  {
    text: "More",
    items: [
      { text: "Shared state model", link: "/design" },
      { text: "Design history", link: "/history" },
      { text: "Change management", link: "/maintainers/changes" },
      { text: "Changelog", link: "https://github.com/skeswa/cog/blob/main/CHANGELOG.md" },
      { text: "Contributing", link: "https://github.com/skeswa/cog/blob/main/CONTRIBUTING.md" },
    ],
  },
];
