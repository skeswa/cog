const SOCIAL_IMAGE = "cog-social-card.png";
const SOCIAL_IMAGE_ALT = "Cog — fine-grained state management for native mobile UI";

/**
 * Builds canonical and social-discovery metadata for one rendered page.
 *
 * VitePress supplies the final title and description after applying page
 * frontmatter and the site title template. The page filename is likewise the
 * post-rewrite route, so `README.md` sources correctly become directory index
 * URLs instead of leaking repository filenames into shared links.
 */
export function socialHead({ page, pageData, title, description }, siteUrl) {
  if (pageData.isNotFound) return [];

  const siteRoot = siteUrl.endsWith("/") ? siteUrl : `${siteUrl}/`;
  const route = page.replace(/\.md$/u, "").replace(/(^|\/)index$/u, "$1");
  const canonical = new URL(route, siteRoot).href;
  const image = new URL(SOCIAL_IMAGE, siteRoot).href;

  return [
    ["link", { rel: "canonical", href: canonical }],
    ["meta", { property: "og:title", content: title }],
    ["meta", { property: "og:description", content: description }],
    ["meta", { property: "og:url", content: canonical }],
    ["meta", { property: "og:image", content: image }],
    ["meta", { property: "og:image:secure_url", content: image }],
    ["meta", { property: "og:image:type", content: "image/png" }],
    ["meta", { property: "og:image:width", content: "1200" }],
    ["meta", { property: "og:image:height", content: "630" }],
    ["meta", { property: "og:image:alt", content: SOCIAL_IMAGE_ALT }],
    ["meta", { name: "twitter:card", content: "summary_large_image" }],
    ["meta", { name: "twitter:title", content: title }],
    ["meta", { name: "twitter:description", content: description }],
    ["meta", { name: "twitter:image", content: image }],
    ["meta", { name: "twitter:image:alt", content: SOCIAL_IMAGE_ALT }],
  ];
}
