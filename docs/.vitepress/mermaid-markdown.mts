import { createHash } from "node:crypto";
import type MarkdownIt from "markdown-it";

/**
 * Rewrites ```` ```mermaid ```` fences into `<MermaidDiagram>` elements so the
 * diagram renders as a real graph rather than as highlighted source.
 *
 * The diagram id is a hash of page path, token index, and content rather than a
 * counter. VitePress renders every page twice — once on the server to produce
 * static HTML, once in the browser to hydrate — and a counter advances
 * independently in each pass, so ids drift apart and hydration mismatches. A
 * hash of the diagram's own identity is stable across both passes and across
 * rebuilds.
 *
 * The source is percent-encoded on its way into the attribute because diagram
 * bodies are multi-line and routinely contain quotes, angle brackets, and
 * braces, all of which would otherwise terminate the attribute or be read as
 * Vue template syntax.
 */
export function renderMermaidDiagrams(markdown: MarkdownIt): void {
  const renderFence = markdown.renderer.rules.fence!;

  markdown.renderer.rules.fence = (tokens, index, options, environment, renderer) => {
    const token = tokens[index]!;
    if (token.info.trim().split(/\s+/u)[0] !== "mermaid") {
      return renderFence(tokens, index, options, environment, renderer);
    }

    const page = typeof environment?.path === "string" ? environment.path : "page";
    const digest = createHash("sha256")
      .update(`${page}\0${index}\0${token.content}`)
      .digest("hex")
      .slice(0, 12);
    const source = encodeURIComponent(token.content.trim());

    return `<MermaidDiagram diagram-id="mermaid-${digest}" source="${source}"></MermaidDiagram>\n`;
  };
}
