import DefaultTheme from "vitepress/theme";
import type { Theme } from "vitepress";
import "@fontsource/instrument-serif/latin-400.css";
import "@fontsource/instrument-serif/latin-400-italic.css";
import "@fontsource/jetbrains-mono/latin-400.css";
import "@fontsource/jetbrains-mono/latin-500.css";
import "@fontsource/jetbrains-mono/latin-700.css";
import CogHome from "./CogHome.vue";
import Layout from "./Layout.vue";
import MermaidDiagram from "./MermaidDiagram.vue";
import "./theme.css";

/**
 * The default VitePress theme plus two global components.
 *
 * `MermaidDiagram` is registered globally because the markdown transform in
 * `../mermaid-markdown.mts` emits the tag directly into rendered pages, which
 * have no import statement of their own to resolve it. `CogHome` is the
 * landing page, written as a component rather than as home-layout frontmatter
 * because it runs a live model of the graph.
 *
 * The layout is overridden rather than extended because the only way to put
 * the Cog mark inside the navigation title's anchor is the slot `Layout.vue`
 * fills; see that file for why the mark is not `themeConfig.logo`.
 *
 * The fonts are self-hosted through `@fontsource` rather than linked from a
 * font CDN, so reading the documentation does not require a third-party
 * request.
 */
export default {
  extends: DefaultTheme,
  Layout,
  enhanceApp({ app }) {
    app.component("CogHome", CogHome);
    app.component("MermaidDiagram", MermaidDiagram);
  },
} satisfies Theme;
