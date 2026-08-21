import DefaultTheme from "vitepress/theme";
import type { Theme } from "vitepress";
import MermaidDiagram from "./MermaidDiagram.vue";
import "./theme.css";

/**
 * The default VitePress theme plus one global component.
 *
 * `MermaidDiagram` is registered globally because the markdown transform in
 * `../mermaid-markdown.mts` emits the tag directly into rendered pages, which
 * have no import statement of their own to resolve it.
 */
export default {
  extends: DefaultTheme,
  enhanceApp({ app }) {
    app.component("MermaidDiagram", MermaidDiagram);
  },
} satisfies Theme;
