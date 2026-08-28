#!/usr/bin/env node

// Proves every permanent CogLint URL has both static DocC outputs and that the
// article source and rendered code listings come from the fixture registry.

import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, readdirSync, rmSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { currentVersion } from "./lib/version.mjs";

/** Repository-owned source, generated, and archive locations. */
const REPO_ROOT = fileURLToPath(new URL("..", import.meta.url));
const LINT_PACKAGE = join(REPO_ROOT, "swift", "Lint");
const DOCC_CATALOG = join(REPO_ROOT, "swift", "Sources", "Cog", "Cog.docc");
const SETUP_GUIDE = join(DOCC_CATALOG, "LintingYourApp.md");
const MODULE_PAGE = join(DOCC_CATALOG, "Cog.md");
const DESIGN_DOC = join(REPO_ROOT, "docs", "swift", "design", "lint.md");
const TEST_ROOT = join(REPO_ROOT, ".build", "coglint-documentation-test");
const GENERATED = join(TEST_ROOT, "generated");
const ARCHIVE = join(REPO_ROOT, ".build", "docs", "Cog.doccarchive");
const VERSION = currentVersion();

/** The settled route oracle, independent of the generator under test. */
const RULES = [
  rule("cog-declaration-suffix", "CogDeclarationSuffix", "CogDeclarationSuffixRule.swift"),
  rule("no-cogs-in-view-init", "NoCogsInViewInit", "NoCogsInViewInitRule.swift"),
  rule("primitives-only-in-ops", "PrimitivesOnlyInOps", "PrimitivesOnlyInOpsRule.swift"),
  rule(
    "initial-state-in-mechanism",
    "InitialStateInMechanism",
    "InitialStateInMechanismRule.swift",
  ),
  rule("manual-cog-private", "ManualCogPrivate", "ManualCogPrivateRule.swift"),
  rule("manual-cog-underscore", "ManualCogUnderscore", "ManualCogUnderscoreRule.swift"),
  rule("no-multi-read-cogs-helper", "NoMultiReadCogsHelper", "NoMultiReadCogsHelperRule.swift"),
  rule("tracked-binding-adapters", "TrackedBindingAdapters", "TrackedBindingAdaptersRule.swift"),
];

main();

/** Runs fixture generation, source parity, DocC conversion, and route checks. */
function main() {
  rmSync(TEST_ROOT, { force: true, recursive: true });
  mkdirSync(GENERATED, { recursive: true });

  console.log("\n==> Generate rule articles from executable fixtures");
  run(
    "swift",
    [
      "run",
      "--package-path",
      LINT_PACKAGE,
      "--scratch-path",
      join(TEST_ROOT, "swift-build"),
      "CogLintDocGenerator",
      "--output",
      GENERATED,
    ],
    { stdio: "inherit" },
  );
  verifyGeneratedParity();
  verifyRuleReference();
  verifyDesignDocTables();
  verifySetupGuide();

  console.log("\n==> Build the statically hosted Cog.docc archive");
  // `docs:api`, not `docs`: this suite verifies DocC routes, and `docs` also
  // builds the VitePress half and merges the two, which would make a CogLint
  // documentation check depend on the docs site's npm dependency tree.
  run("mise", ["run", "docs:api"], { cwd: REPO_ROOT, stdio: "inherit" });
  verifyArchive();

  if (existsSync(join(REPO_ROOT, "Package.resolved"))) {
    fail("documentation verification left a root Package.resolved behind");
  }
  console.log(
    `\nPASS LINT-22: all ${RULES.length} permanent URLs resolve and every article matches its fixture corpus`,
  );
}

/** Requires every rule article to be reachable from both DocC topic lists. */
function verifyRuleReference() {
  // An article DocC never links is published but unreachable: the diagnostic
  // URL still resolves, while a reader browsing the rule reference cannot find
  // the rule at all. Both pages carry the list, so both are checked.
  for (const page of [MODULE_PAGE, SETUP_GUIDE]) {
    const contents = readFileSync(page, "utf8");
    const referenced = [...contents.matchAll(/<doc:([A-Za-z]+)>/g)].map((match) => match[1]);
    for (const entry of RULES) {
      if (!referenced.includes(entry.articleStem)) {
        fail(`${page} does not list <doc:${entry.articleStem}> in its rule reference`);
      }
    }
  }
  console.log(`==> Both DocC topic lists reach all ${RULES.length} rule articles`);
}

/** Requires the design doc's rule and URL tables to carry every enabled rule. */
function verifyDesignDocTables() {
  // The fixture registry, DocC topic lists, and generated articles are all
  // slug-checked elsewhere; the design doc's two tables were the one roster
  // nothing enforced, so a ninth rule could silently miss the human-readable
  // index. Each slug must open a row in both the required-form table and the
  // permanent-URL table.
  const design = readFileSync(DESIGN_DOC, "utf8");
  const lines = design.split("\n");
  for (const entry of RULES) {
    const rows = lines.filter((line) => line.startsWith(`| \`${entry.slug}\``)).length;
    if (rows < 2) {
      fail(`${entry.slug} is missing a rule-table or URL-table row in ${DESIGN_DOC}`);
    }
    if (!design.includes(`/cog/documentation/cog/${entry.route}`)) {
      fail(`${entry.slug} is missing its permanent URL in ${DESIGN_DOC}`);
    }
  }
  console.log(`==> The design doc's tables carry all ${RULES.length} rules`);
}

/** Requires the documented product reference to equal the URL-derived package identity. */
function verifySetupGuide() {
  const guide = readFileSync(SETUP_GUIDE, "utf8");
  const dependency = guide.match(
    /\.package\(\s*url: "(https:\/\/github\.com\/skeswa\/coglint-plugins\.git)",\s*exact: "([^"]+)"\s*\)/s,
  );
  const plugin = guide.match(
    /\.plugin\(\s*name: "CogLintBuildToolPlugin",\s*package: "([^"]+)"\s*\)/s,
  );
  if (dependency === null || plugin === null) {
    fail("lint setup guide is missing its exact Channel B dependency or build-tool plugin");
  }

  const repository = new URL(dependency[1]).pathname.split("/").at(-1);
  const packageIdentity = repository.replace(/\.git$/, "").toLowerCase();
  if (plugin[1] !== packageIdentity) {
    fail(`lint setup guide references package ${plugin[1]}; URL identity is ${packageIdentity}`);
  }
  if (dependency[2] !== VERSION) {
    fail(`lint setup guide pins ${dependency[2]}; expected the current release ${VERSION}`);
  }
  console.log(`==> Setup guide binds CogLintBuildToolPlugin to ${packageIdentity} ${VERSION}`);
}

/** Defines one canonical rule route and its two independent source owners. */
function rule(slug, articleStem, ruleSource) {
  return {
    slug,
    articleStem,
    articleFile: `${articleStem}.md`,
    route: slug.replaceAll("-", ""),
    ruleSource,
  };
}

/** Requires checked-in articles to equal the generator output byte for byte. */
function verifyGeneratedParity() {
  const generatedFiles = readdirSync(GENERATED)
    .filter((name) => name.endsWith(".md"))
    .sort();
  const expectedFiles = RULES.map((entry) => entry.articleFile).sort();
  if (JSON.stringify(generatedFiles) !== JSON.stringify(expectedFiles)) {
    fail(`generator emitted ${generatedFiles.join(", ")}; expected ${expectedFiles.join(", ")}`);
  }

  for (const entry of RULES) {
    const generated = readFileSync(join(GENERATED, entry.articleFile), "utf8");
    const checkedIn = readFileSync(join(DOCC_CATALOG, entry.articleFile), "utf8");
    if (generated !== checkedIn) {
      fail(`${entry.articleFile} differs from its fixture-generated source`);
    }
    for (const heading of [
      "## Triggering examples",
      "## Non-triggering examples",
      "## Accepted evasions",
    ]) {
      if (!generated.includes(heading)) {
        fail(`${entry.articleFile} is missing ${heading}`);
      }
    }
  }
  console.log(`==> Checked-in articles are byte-identical to all ${RULES.length} fixture renders`);
}

/** Requires each canonical HTML route and matching DocC data payload. */
function verifyArchive() {
  for (const entry of RULES) {
    const canonicalURL = `https://skeswa.github.io/cog/documentation/cog/${entry.route}`;
    const html = join(ARCHIVE, "documentation", "cog", entry.route, "index.html");
    const data = join(ARCHIVE, "data", "documentation", "cog", `${entry.route}.json`);
    if (!existsSync(html) || !existsSync(data)) {
      fail(`${canonicalURL} is missing its HTML route or DocC data payload`);
    }

    const ruleSource = readFileSync(
      join(LINT_PACKAGE, "Sources", "CogLintCore", entry.ruleSource),
      "utf8",
    );
    if (!ruleSource.includes(canonicalURL)) {
      fail(`${entry.slug} diagnostic source does not carry ${canonicalURL}`);
    }

    const payload = JSON.parse(readFileSync(data, "utf8"));
    const expectedIdentifier = `doc://Cog/documentation/Cog/${entry.articleStem}`;
    if (
      payload.identifier?.url !== expectedIdentifier ||
      payload.metadata?.title !== entry.slug ||
      payload.metadata?.role !== "article"
    ) {
      fail(`${entry.slug} DocC identity or title drifted from its permanent route`);
    }

    const article = readFileSync(join(DOCC_CATALOG, entry.articleFile), "utf8");
    const sourceListings = swiftListings(article);
    const renderedListings = (payload.primaryContentSections ?? [])
      .flatMap((section) => section.content ?? [])
      .filter((item) => item.type === "codeListing" && item.syntax === "swift")
      .map((item) => item.code.join("\n"));
    if (JSON.stringify(renderedListings) !== JSON.stringify(sourceListings)) {
      fail(`${entry.slug} DocC payload code listings differ from the fixture article`);
    }
    console.log(`==> ${canonicalURL}`);
  }
}

/** Extracts every Swift fence, including dynamically lengthened fixture fences. */
function swiftListings(markdown) {
  const listings = [];
  const pattern = /^(`{3,})swift\n([\s\S]*?)^\1$/gm;
  for (const match of markdown.matchAll(pattern)) {
    listings.push(match[2].endsWith("\n") ? match[2].slice(0, -1) : match[2]);
  }
  return listings;
}

/** Runs one required subprocess and preserves its own output when requested. */
function run(command, arguments_, options = {}) {
  const result = spawnSync(command, arguments_, {
    maxBuffer: 64 * 1024 * 1024,
    ...options,
  });
  if (result.error !== undefined) {
    fail(`could not run ${command}: ${result.error.message}`);
  }
  if (result.signal !== null && result.signal !== undefined) {
    fail(`${command} was killed by ${result.signal}`);
  }
  if (result.status !== 0) {
    fail(`${command} exited with status ${result.status}`);
  }
  return result;
}

/** Reports a documentation-contract failure without changing generated articles. */
function fail(message) {
  console.error(`error: CogLint documentation test: ${message}`);
  process.exit(1);
}
