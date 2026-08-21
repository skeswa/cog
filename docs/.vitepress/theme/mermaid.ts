import type { MermaidConfig } from "mermaid";

type Mermaid = (typeof import("mermaid"))["default"];

let mermaidPromise: Promise<Mermaid> | undefined;

/**
 * Loads mermaid exactly once per page session, without configuring it.
 *
 * The import is dynamic and memoized because mermaid is megabytes of
 * JavaScript and only the Kotlin documents contain diagrams; a static import
 * would put that weight on every page. Configuration is deliberately *not*
 * done here — see `mermaidConfig`.
 */
export function loadMermaid(): Promise<Mermaid> {
  mermaidPromise ??= import("mermaid").then(({ default: mermaid }) => mermaid);
  return mermaidPromise;
}

/**
 * The mermaid configuration for one appearance.
 *
 * Every colour is a literal hex string rather than a `var(--vp-…)` reference.
 * Mermaid does not hand these to CSS: it parses them and derives further
 * colours arithmetically (borders, contrasting label text, hover states), so a
 * `var()` string reaches a colour parser that cannot resolve it and the whole
 * theme silently degrades. That is also why the palette has to be duplicated
 * per appearance instead of inherited from the stylesheet.
 *
 * `htmlLabels` stays at mermaid's default of `true`: the Kotlin diagrams use
 * `<br/>` inside node labels, which renders only under HTML labels and would
 * otherwise print literally.
 */
export function mermaidConfig(dark: boolean): MermaidConfig {
  const palette = dark
    ? {
        background: "#1b1b1f",
        surface: "#202127",
        surfaceAlt: "#161618",
        ink: "#dfdfd6",
        line: "#98989f",
        accent: "#a8b1ff",
        divider: "#2e2e32",
      }
    : {
        background: "#ffffff",
        surface: "#f6f6f7",
        surfaceAlt: "#ffffff",
        ink: "#3c3c43",
        line: "#67676c",
        accent: "#3451b2",
        divider: "#e2e2e3",
      };

  return {
    startOnLoad: false,
    suppressErrorRendering: true,
    securityLevel: "strict",
    theme: "base",
    fontFamily: "var(--vp-font-family-base)",
    themeVariables: {
      darkMode: dark,
      background: palette.background,
      primaryColor: palette.surface,
      primaryTextColor: palette.ink,
      primaryBorderColor: palette.accent,
      secondaryColor: palette.surfaceAlt,
      tertiaryColor: palette.surfaceAlt,
      lineColor: palette.line,
      textColor: palette.ink,
      clusterBkg: palette.surfaceAlt,
      clusterBorder: palette.divider,
      edgeLabelBackground: palette.background,
    },
  };
}
