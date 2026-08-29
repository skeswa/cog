#!/usr/bin/env node

// Proves that every shareable VitePress route carries a complete, internally
// consistent social preview and that its raster asset has the dimensions the
// metadata promises. This runs against built HTML because a correct-looking
// config is not evidence that VitePress emitted the expected tags after page
// rewrites and title-template expansion.

import { readFileSync, readdirSync } from "node:fs";
import { join, relative } from "node:path";
import { fileURLToPath } from "node:url";

const REPO_ROOT = fileURLToPath(new URL("..", import.meta.url));
const SITE_ROOT = join(REPO_ROOT, "docs/.vitepress/dist");
const SOCIAL_IMAGE = "cog-social-card.png";
const configuredSite = process.env.VITEPRESS_SITE_URL ?? "https://skeswa.github.io/cog/";
const SITE_URL = configuredSite.endsWith("/") ? configuredSite : `${configuredSite}/`;
const EXPECTED_IMAGE = new URL(SOCIAL_IMAGE, SITE_URL).href;

main();

function main() {
  verifyPng(join(SITE_ROOT, SOCIAL_IMAGE));
  const pages = htmlFiles(SITE_ROOT).filter((path) => !path.endsWith("/404.html"));
  if (pages.length === 0) fail("the VitePress build contains no shareable HTML pages");
  for (const path of pages) verifyPage(path);
  console.log(
    `check-docs-social-metadata: ${pages.length} page(s) carry canonical Open Graph and Twitter cards`,
  );
}

/** Recursively returns built HTML paths without assuming a fixed page map. */
function htmlFiles(directory) {
  return readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
    const path = join(directory, entry.name);
    if (entry.isDirectory()) return htmlFiles(path);
    return entry.isFile() && entry.name.endsWith(".html") ? [path] : [];
  });
}

/** Checks the PNG signature and IHDR instead of trusting its filename. */
function verifyPng(path) {
  const image = readFileSync(path);
  const signature = "89504e470d0a1a0a";
  if (image.subarray(0, 8).toString("hex") !== signature) fail(`${sitePath(path)} is not a PNG`);
  const width = image.readUInt32BE(16);
  const height = image.readUInt32BE(20);
  if (width !== 1200 || height !== 630) {
    fail(`${sitePath(path)} is ${width}×${height}, expected 1200×630`);
  }
}

/** Checks one page's tags and the relationships Slack and other crawlers use. */
function verifyPage(path) {
  const html = readFileSync(path, "utf8");
  const canonical = uniqueValue(html, "link", "rel", "canonical", "href", path);
  const openGraphTitle = uniqueValue(html, "meta", "property", "og:title", "content", path);
  const openGraphDescription = uniqueValue(
    html,
    "meta",
    "property",
    "og:description",
    "content",
    path,
  );
  const openGraphUrl = uniqueValue(html, "meta", "property", "og:url", "content", path);
  const openGraphImage = uniqueValue(html, "meta", "property", "og:image", "content", path);
  const imageAlt = uniqueValue(html, "meta", "property", "og:image:alt", "content", path);

  requireEqual(canonical, expectedCanonical(path), `${sitePath(path)} canonical route`);
  requireEqual(openGraphUrl, canonical, `${sitePath(path)} canonical and og:url`);
  requireEqual(
    uniqueValue(html, "meta", "property", "og:type", "content", path),
    "website",
    `${sitePath(path)} Open Graph type`,
  );
  requireEqual(
    uniqueValue(html, "meta", "property", "og:site_name", "content", path),
    "Cog",
    `${sitePath(path)} Open Graph site name`,
  );
  requireEqual(
    uniqueValue(html, "meta", "property", "og:locale", "content", path),
    "en_US",
    `${sitePath(path)} Open Graph locale`,
  );
  requireEqual(openGraphImage, EXPECTED_IMAGE, `${sitePath(path)} social image`);
  requireEqual(
    uniqueValue(html, "meta", "property", "og:image:secure_url", "content", path),
    EXPECTED_IMAGE,
    `${sitePath(path)} secure social image`,
  );
  requireEqual(
    uniqueValue(html, "meta", "property", "og:image:type", "content", path),
    "image/png",
    `${sitePath(path)} social image type`,
  );
  requireEqual(
    `${uniqueValue(html, "meta", "property", "og:image:width", "content", path)}×${uniqueValue(html, "meta", "property", "og:image:height", "content", path)}`,
    "1200×630",
    `${sitePath(path)} social image dimensions`,
  );
  requireEqual(
    uniqueValue(html, "meta", "name", "twitter:card", "content", path),
    "summary_large_image",
    `${sitePath(path)} Twitter card kind`,
  );
  requireEqual(
    uniqueValue(html, "meta", "name", "twitter:title", "content", path),
    openGraphTitle,
    `${sitePath(path)} social titles`,
  );
  requireEqual(
    uniqueValue(html, "meta", "name", "twitter:description", "content", path),
    openGraphDescription,
    `${sitePath(path)} social descriptions`,
  );
  requireEqual(
    uniqueValue(html, "meta", "name", "twitter:image", "content", path),
    EXPECTED_IMAGE,
    `${sitePath(path)} Twitter image`,
  );
  requireEqual(
    uniqueValue(html, "meta", "name", "twitter:image:alt", "content", path),
    imageAlt,
    `${sitePath(path)} social image alternatives`,
  );
}

/** Maps one emitted HTML file back to its clean public URL. */
function expectedCanonical(path) {
  const route = sitePath(path)
    .replace(/\.html$/u, "")
    .replace(/(^|\/)index$/u, "$1");
  return new URL(route, SITE_URL).href;
}

/** Reads exactly one value from a tag whose identifying attribute is known. */
function uniqueValue(html, element, keyName, keyValue, valueName, path) {
  const expression = new RegExp(
    `<${element}\\s+${keyName}="${escapeRegExp(keyValue)}"\\s+${valueName}="([^"]*)"[^>]*>`,
    "gu",
  );
  const values = [...html.matchAll(expression)].map((match) => match[1]);
  if (values.length !== 1 || values[0] === "") {
    fail(
      `${sitePath(path)} has ${values.length} non-empty <${element} ${keyName}=${JSON.stringify(keyValue)}> value(s), expected one`,
    );
  }
  return values[0];
}

function escapeRegExp(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/gu, "\\$&");
}

function requireEqual(actual, expected, label) {
  if (actual !== expected)
    fail(`${label} is ${JSON.stringify(actual)}, expected ${JSON.stringify(expected)}`);
}

function sitePath(path) {
  return relative(SITE_ROOT, path);
}

function fail(message) {
  console.error(`error: check-docs-social-metadata: ${message}`);
  process.exit(1);
}
