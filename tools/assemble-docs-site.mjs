// Assembles the published documentation site from its two halves.
//
//     node tools/assemble-docs-site.mjs [--docc PATH] [--site PATH] [--out PATH]
//
// GitHub Pages serves exactly one deployment per repository, and
// `actions/deploy-pages` replaces that deployment wholesale rather than merging
// into it. Cog needs two things at one origin: the VitePress site built from
// `docs/`, and the DocC archive built by `mise run docs:api`. So they are
// merged here, into one directory, and uploaded as one artifact.
//
// The layout is an overlay, and it is safe because the two halves barely
// intersect. DocC owns `documentation/`, `data/`, `css/`, `js/`, `img/`,
// `index/`, `metadata.json`, and `theme-settings.json`; VitePress owns
// `assets/`, `404.html`, `hashmap.json`, `sitemap.xml`, and the `swift/`,
// `kotlin/`, and `maintainers/` route directories. DocC is copied first and
// VitePress second, so the only files VitePress takes over are the ones it
// should: the root `index.html` and the favicons.
//
// Losing DocC's root `index.html` costs nothing. It is a redirect shim into
// `documentation/cog`, and because the archive was transformed for static
// hosting (`--transform-for-static-hosting`), every documentation route
// already has its own `index.html` on disk. `/cog/documentation/cog/` keeps
// resolving with VitePress sitting at the root.
//
// The published URLs this arrangement preserves are load-bearing: `README.md`
// and the release runbook link to them, and they are what a consumer has
// bookmarked. So the merge is not trusted — it is checked, by `REQUIRED_ROUTES`
// below, and a missing route fails the build rather than publishing a site
// that 404s its own API reference.
//
// The merge also finishes the site's agent-readable twin. VitePress's half
// already ships a `.md` beside every HTML route and an `llms.txt` index of
// them (`vitepress-plugin-llms`, in `docs/.vitepress/config.mts`). DocC's half
// writes its Markdown into `data/documentation/`, one file per page, which is
// not where a fetcher that appends `.md` to a page URL will look. So the
// archive's twins are mirrored to `documentation/<route>.md`, next to the
// route's `index.html`, and the top-level articles — the getting-started
// tutorial, the lint guide, and the rule pages that every `coglint` finding
// links to — are appended to `llms.txt` and `llms-full.txt` so the index
// covers the whole site rather than half of it.

import { cp, mkdir, readdir, readFile, rm, stat, writeFile } from "node:fs/promises";
import { existsSync } from "node:fs";
import { dirname, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import process from "node:process";

const REPO_ROOT = resolve(fileURLToPath(new URL("..", import.meta.url)));

const DEFAULT_DOCC = resolve(REPO_ROOT, ".build/docs/Cog.doccarchive");
const DEFAULT_SITE = resolve(REPO_ROOT, "docs/.vitepress/dist");
const DEFAULT_OUT = resolve(REPO_ROOT, ".build/docs-site");

/** Where the assembled site is served from; the `llms.txt` links are absolute. */
const configuredSite = process.env.VITEPRESS_SITE_URL ?? "https://skeswa.github.io/cog/";
const SITE_URL = configuredSite.endsWith("/") ? configuredSite.slice(0, -1) : configuredSite;

/** DocC's manifest of every Markdown twin it wrote, at the archive root. */
const MARKDOWN_MANIFEST = "Cog-markdown-manifest.json";

/**
 * Paths that must exist in the assembled site, relative to its root.
 *
 * Each one stands for a published URL. The first two are the API reference
 * itself and the JSON payload its single-page app fetches to render — a site
 * with the routes but not the data looks fine until every page loads empty.
 * The last two are the article routes linked by name from outside the archive:
 * `README.md` points at `lintingyourapp`, and `gettingstarted` is a bookmarked
 * URL the site's own `docs/swift/getting-started.md` now fronts.
 */
const REQUIRED_ROUTES = [
  "documentation/cog/index.html",
  "data/documentation/cog.json",
  "documentation/cog/gettingstarted/index.html",
  "documentation/cog/lintingyourapp/index.html",
];

/** Paths that must exist in the assembled site from the VitePress half. */
const REQUIRED_SITE_ROUTES = [
  "index.html",
  "swift/index.html",
  "kotlin/index.html",
  "llms.txt",
  "llms-full.txt",
  "swift/agent-guide.md",
];

/**
 * Markdown twins that must exist beside their routes after the mirror.
 *
 * `lintingyourapp.md` is the page `coglint` diagnostics link to and the one
 * `README.md` tells an agent to read as Markdown, so it is the twin whose
 * absence would be noticed by a machine rather than a person.
 */
const REQUIRED_MARKDOWN_TWINS = [
  "documentation/cog.md",
  "documentation/cog/gettingstarted.md",
  "documentation/cog/lintingyourapp.md",
  "documentation/cog/primitivesonlyinops.md",
];

/**
 * Pages whose rendered content must be present in the HTML itself, with the
 * title each one has to carry.
 *
 * `mise run docs:api` passes
 * `--experimental-transform-for-static-hosting-with-content`, which is what
 * bakes a real `<title>`, a description, and the article body into every route
 * file. Without it DocC emits one byte-identical app shell titled
 * "Documentation" for all ~250 routes, and every reader that does not run
 * JavaScript — a crawler, a link unfurl, scripting turned off — gets a blank
 * page from half of this site while the VitePress half reads fine.
 *
 * The flag is experimental. If a toolchain upgrade drops it, `docc` rejects the
 * unknown option and the build fails loudly, which is the good case; if it ever
 * becomes a silent no-op instead, this check is what notices. A shell is
 * indistinguishable from a real page by size or route alone, so the assertion
 * is on the title: the shell's is always "Documentation".
 */
const REQUIRED_CONTENT = [
  { path: "documentation/cog/gettingstarted/index.html", title: "Getting started" },
  { path: "documentation/cog/lintingyourapp/index.html", title: "Linting your app" },
];

function usage() {
  return (
    "usage: node tools/assemble-docs-site.mjs [--docc path/to/Cog.doccarchive] " +
    "[--site path/to/vitepress/dist] [--out path/to/output]\n"
  );
}

function parseArguments(argv) {
  let docc = DEFAULT_DOCC;
  let site = DEFAULT_SITE;
  let out = DEFAULT_OUT;

  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    const value = argv[index + 1];
    switch (argument) {
      case "--docc":
        if (value === undefined) fail(`\`--docc\` needs a path.\n${usage()}`);
        docc = resolve(value);
        index += 1;
        break;
      case "--site":
        if (value === undefined) fail(`\`--site\` needs a path.\n${usage()}`);
        site = resolve(value);
        index += 1;
        break;
      case "--out":
        if (value === undefined) fail(`\`--out\` needs a path.\n${usage()}`);
        out = resolve(value);
        index += 1;
        break;
      case "-h":
      case "--help":
        process.stdout.write(usage());
        process.exit(0);
        break;
      default:
        fail(`unrecognized argument \`${argument}\`.\n${usage()}`);
    }
  }

  return { docc, site, out };
}

function fail(message) {
  process.stderr.write(`assemble-docs-site: ${message}\n`);
  process.exit(1);
}

async function requireDirectory(path, what, remedy) {
  let info;
  try {
    info = await stat(path);
  } catch {
    fail(`${what} is missing at ${path}.\n  ${remedy}`);
  }
  if (!info.isDirectory()) fail(`${what} at ${path} is not a directory.\n  ${remedy}`);
}

async function main() {
  const { docc, site, out } = parseArguments(process.argv.slice(2));

  await requireDirectory(
    docc,
    "The DocC archive",
    "Build it with `mise run docs:api`, or pass `--docc` if it lives elsewhere.",
  );
  await requireDirectory(
    site,
    "The VitePress site",
    "Build it with `mise run docs:build`, or pass `--site` if it lives elsewhere.",
  );

  await rm(out, { recursive: true, force: true });
  await mkdir(out, { recursive: true });

  // Order matters: DocC first, VitePress over the top. See the header.
  await cp(docc, out, { recursive: true });
  await cp(site, out, { recursive: true, force: true });

  const missing = [...REQUIRED_ROUTES, ...REQUIRED_SITE_ROUTES].filter(
    (route) => !existsSync(resolve(out, route)),
  );
  if (missing.length > 0) {
    fail(
      "the assembled site is missing routes that are published URLs:\n" +
        missing.map((route) => `  - ${route}`).join("\n") +
        "\n  Publishing this would break links that README.md and the release " +
        "runbook already point at.",
    );
  }

  const shells = [];
  for (const { path: route, title } of REQUIRED_CONTENT) {
    const html = await readFile(resolve(out, route), "utf8");
    if (!html.includes(`<title>${title}</title>`)) shells.push({ route, title });
  }
  if (shells.length > 0) {
    fail(
      "the API reference was built without its page content:\n" +
        shells.map(({ route, title }) => `  - ${route} is not titled "${title}"`).join("\n") +
        "\n  `mise run docs:api` must pass " +
        "`--experimental-transform-for-static-hosting-with-content`, or every one of\n" +
        "  these pages is an empty app shell to anything that does not run JavaScript.",
    );
  }

  const twins = await mirrorMarkdownTwins(out);
  const articles = await appendApiReferenceToIndexes(docc, out);

  const missingTwins = REQUIRED_MARKDOWN_TWINS.filter((twin) => !existsSync(resolve(out, twin)));
  if (missingTwins.length > 0) {
    fail(
      "the API reference was built without its Markdown twins:\n" +
        missingTwins.map((twin) => `  - ${twin}`).join("\n") +
        "\n  `mise run docs:api` must pass `--enable-experimental-markdown-output` and\n" +
        "  `--enable-experimental-markdown-output-manifest`, or the lint articles that\n" +
        "  `coglint` findings link to are unreadable to a coding agent.",
    );
  }

  process.stdout.write(`assemble-docs-site: assembled ${out}\n`);
  for (const route of REQUIRED_ROUTES) process.stdout.write(`  verified ${route}\n`);
  for (const { path: route } of REQUIRED_CONTENT) {
    process.stdout.write(`  verified rendered content in ${route}\n`);
  }
  process.stdout.write(`  mirrored ${twins} Markdown twin(s) beside their routes\n`);
  process.stdout.write(`  indexed ${articles} API reference article(s) in llms.txt\n`);
}

/**
 * Copies every `data/documentation/<route>.md` to `documentation/<route>.md`.
 *
 * The walk is over the files DocC actually wrote rather than over the
 * manifest, because the manifest names pages by identifier and the file names
 * are those identifiers lowercased — deriving one from the other would be a
 * second copy of DocC's naming rule. The manifest is used only for titles.
 */
async function mirrorMarkdownTwins(out) {
  const source = resolve(out, "data/documentation");
  if (!existsSync(source)) return 0;
  let count = 0;
  for (const file of await markdownFiles(source)) {
    const target = resolve(out, "documentation", relative(source, file));
    await mkdir(dirname(target), { recursive: true });
    await cp(file, target);
    count += 1;
  }
  return count;
}

async function markdownFiles(directory) {
  const entries = await readdir(directory, { withFileTypes: true });
  const files = [];
  for (const entry of entries) {
    const path = resolve(directory, entry.name);
    if (entry.isDirectory()) files.push(...(await markdownFiles(path)));
    else if (entry.isFile() && entry.name.endsWith(".md")) files.push(path);
  }
  return files;
}

/**
 * Appends the API reference's top-level articles to the two `llms.txt` files.
 *
 * Only articles directly under the module — `/documentation/Cog/<Name>` — are
 * listed. The synthesized "Equatable Implementations" pages and the ~250
 * symbol pages are reachable by appending `.md` to any reference URL, and
 * the index says so once instead of listing them all; an `llms.txt` is a
 * map, and a map that lists every symbol is the site again.
 */
async function appendApiReferenceToIndexes(docc, out) {
  const manifestPath = resolve(docc, MARKDOWN_MANIFEST);
  if (!existsSync(manifestPath)) {
    fail(
      `the DocC archive has no ${MARKDOWN_MANIFEST}.\n  \`mise run docs:api\` must pass ` +
        "`--enable-experimental-markdown-output-manifest`.",
    );
  }
  const manifest = JSON.parse(await readFile(manifestPath, "utf8"));
  const articles = (manifest.documents ?? [])
    .filter((document) => document.documentType === "article")
    .filter((document) => document.identifier.split("/").length === 4)
    .sort((a, b) => a.title.localeCompare(b.title));

  const entries = articles.map((document) => {
    const route = `${document.identifier.toLowerCase()}.md`;
    if (!existsSync(resolve(out, route.slice(1))))
      fail(`${route} is in the manifest but not on disk`);
    return `- [${document.title}](${SITE_URL}${route})`;
  });
  const section = [
    "",
    "## API reference",
    "",
    "The DocC reference for the shipping Swift library. Every symbol page has a",
    `Markdown twin at the same URL with \`.md\` appended; the module root is`,
    `${SITE_URL}/documentation/cog.md. The articles:`,
    "",
    ...entries,
    "",
  ].join("\n");

  for (const index of ["llms.txt", "llms-full.txt"]) {
    const path = resolve(out, index);
    if (!existsSync(path))
      fail(`the VitePress site has no ${index}; is vitepress-plugin-llms configured?`);
    await writeFile(path, (await readFile(path, "utf8")).trimEnd() + "\n" + section);
  }
  return entries.length;
}

await main();
