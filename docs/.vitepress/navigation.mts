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
        text: "Implementation",
        items: [
          { text: "Implementation plan", link: "/swift/impl/plan" },
          { text: "Test scenarios", link: "/swift/impl/scenarios" },
          { text: "Task breakdown", link: "/swift/impl/tasks" },
          { text: "Benchmark results", link: "/swift/impl/benchmarks" },
          { text: "Profiling and optimization", link: "/swift/impl/optimization" },
          {
            text: "Arena specialization research",
            link: "/swift/impl/arena-optimization-plan-2026-08-20",
          },
        ],
      },
    ],
  },
];

const kotlinSidebar: DefaultTheme.SidebarItem[] = [
  {
    text: "Cog for Kotlin",
    link: "/kotlin/",
    items: [
      { text: "Core design", link: "/kotlin/exploration" },
      { text: "Worked weather example", link: "/kotlin/example" },
      { text: "Flow map", link: "/kotlin/flows" },
      { text: "Effects and background work", link: "/kotlin/effects" },
      { text: "Performance model", link: "/kotlin/perf" },
    ],
  },
];

const maintainersSidebar: DefaultTheme.SidebarItem[] = [
  {
    text: "Maintainers",
    items: [
      { text: "CI and runner operations", link: "/maintainers/ci" },
      { text: "Releasing Cog for Swift", link: "/maintainers/releasing" },
    ],
  },
];

const historySidebar: DefaultTheme.SidebarItem[] = [
  {
    text: "History",
    items: [{ text: "Dart and Flutter snapshot", link: "/dump-2026-08-06" }],
  },
];

export const sidebar: DefaultTheme.Sidebar = {
  "/swift/": swiftSidebar,
  "/kotlin/": kotlinSidebar,
  "/maintainers/": maintainersSidebar,
  "/dump-2026-08-06": historySidebar,
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
      { text: "Maintainer runbooks", link: "/maintainers/ci" },
      { text: "Dart and Flutter snapshot", link: "/dump-2026-08-06" },
      { text: "Changelog", link: "https://github.com/skeswa/cog/blob/main/CHANGELOG.md" },
      { text: "Contributing", link: "https://github.com/skeswa/cog/blob/main/CONTRIBUTING.md" },
    ],
  },
];
