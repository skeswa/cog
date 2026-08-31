/**
 * Preload links for the display serif.
 *
 * The `@fontsource` faces are imported from the theme entry, so the browser
 * only learns they exist once it has fetched and parsed the bundled
 * stylesheet. First paint happens the moment that stylesheet is done, which is
 * before the font it just asked for can arrive — the headline is painted in
 * the fallback every single time, and the swap lands a beat later. Announcing
 * the file in the document head instead starts the fetch off the preload
 * scanner, in parallel with the stylesheet rather than behind it, and 21KB of
 * same-origin woff2 generally beats the CSS and JS it is racing.
 *
 * Only the two display faces are listed. They are the ones that visibly
 * reflow, and every extra preload is bandwidth taken from the stylesheet that
 * is blocking the render — the mono faces measure close enough to their
 * fallbacks to swap unnoticed, and paying for them here would make the thing
 * this is meant to fix arrive later.
 *
 * The filenames are content-hashed, so the assets are matched by their stable
 * `@fontsource` stem. A stem that matches nothing yields nothing rather than
 * a broken link; `mise run docs:build` is what would surface a rename, since
 * the preloads simply stop appearing in the built head.
 */
const PRELOADED_FONT_STEMS = [
  "instrument-serif-latin-400-normal",
  "instrument-serif-latin-400-italic",
];

/**
 * Builds the preload links for one rendered page.
 *
 * VitePress passes every emitted asset URL, already carrying `base`, and calls
 * this for each page — including the 404, which wants the font as much as any
 * other page does.
 */
export function fontPreloadHead(assets = []) {
  return PRELOADED_FONT_STEMS.flatMap((stem) => {
    const href = assets.find((asset) => new RegExp(`/${stem}\\.[^/.]+\\.woff2$`, "u").test(asset));
    if (!href) return [];

    // `crossorigin` is not optional: fonts are always fetched in CORS mode, so
    // a preload without it warms a cache entry the font request cannot use and
    // the file is downloaded twice.
    return [["link", { rel: "preload", href, as: "font", type: "font/woff2", crossorigin: "" }]];
  });
}
