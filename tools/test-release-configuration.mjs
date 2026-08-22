#!/usr/bin/env node

// Guards the one-time Release Please bootstrap and the exact first generated
// release payload. These checks are deliberately static: they run without a
// GitHub token and catch configuration drift before automation can publish it.

import { existsSync, readFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { currentVersion } from "./lib/version.mjs";
import { collectGitCommits, collectJjRevisions } from "./lib/changes.mjs";

const REPO_ROOT = fileURLToPath(new URL("..", import.meta.url));
const BOOTSTRAP_SHA = "16ade4bac358bf1c6f6dbc6e95fad2d467600250";
const ACTION_SHA = "45996ed1f6d02564a971a2fa1b5860e934307cf7";
const PUBLISHED_CHANGELOG_SHA256 =
  "ce6fd89e88a449bb3f9d8e68ac9001b98876fd4d2617a8df16ddaa0830750c40";
const SCHEMA =
  "https://raw.githubusercontent.com/googleapis/release-please/v17.6.0/schemas/config.json";
const MOVING_FILES = [
  "AGENTS.md",
  "CLAUDE.md",
  "README.md",
  "docs/swift/README.md",
  "swift/Sources/Cog/Cog.docc/GettingStarted.md",
  "swift/Sources/Cog/Cog.docc/LintingYourApp.md",
];

main();

function main() {
  const config = json("release-please-config.json");
  const manifest = json(".release-please-manifest.json");
  const root = config.packages?.["."];
  const version = currentVersion();

  requireEqual(config.$schema, SCHEMA, "Release Please schema pin");
  requireEqual(config["bootstrap-sha"], BOOTSTRAP_SHA, "bootstrap revision");
  verifyManifestState(manifest, version);
  requireEqual(root?.["release-type"], "simple", "release strategy");
  requireEqual(root?.["version-file"], "version.txt", "version source");
  requireEqual(root?.["bump-minor-pre-major"], true, "pre-1.0 breaking bump");
  requireEqual(root?.["bump-patch-for-minor-pre-major"], false, "pre-1.0 feature bump");
  for (const setting of [
    "include-component-in-tag",
    "include-v-in-tag",
    "include-v-in-release-name",
  ]) {
    requireEqual(root?.[setting], false, setting);
  }
  for (const setting of ["draft-pull-request", "draft", "force-tag-creation"]) {
    requireEqual(root?.[setting], true, setting);
  }

  const moving = (root?.["extra-files"] ?? []).map((entry) => entry.path).sort();
  requireEqual(
    JSON.stringify(moving),
    JSON.stringify([...MOVING_FILES].sort()),
    "moving version files",
  );
  for (const path of MOVING_FILES) {
    const source = read(path);
    if (
      !source.includes("x-release-please-version") &&
      !source.includes("x-release-please-start-version")
    ) {
      fail(`${path} is managed but carries no generic version marker`);
    }
    verifyMovingVersionBlocks(path, source, version);
  }
  if (moving.includes("package.json") || json("package.json").version !== "0.0.0") {
    fail("the private documentation package was coupled to the Swift release");
  }

  verifyInitialNotes();
  verifyChangelogState(version);
  const releaseWorkflow = read(".github/workflows/release.yml", false);
  if (
    releaseWorkflow !== null &&
    !releaseWorkflow.includes(`googleapis/release-please-action@${ACTION_SHA}`)
  ) {
    fail("release.yml does not pin release-please-action v5.0.0 by its full SHA");
  }
  console.log("test-release-configuration: Release Please bootstrap and 0.5.0 notes passed");
}

/** Accepts the checked-in bootstrap once, then requires manifest and runtime versions to agree. */
function verifyManifestState(manifest, version) {
  const recorded = manifest["."];
  if (recorded === "0.0.0") {
    requireEqual(version, "0.4.0", "pre-bootstrap runtime version");
    return;
  }
  if (compareVersions(recorded, "0.5.0") < 0) {
    fail(`post-bootstrap manifest version ${recorded} predates the first Release Please release`);
  }
  requireEqual(recorded, version, "post-bootstrap manifest and runtime version");
}

/** Every semantic version inside a moving marker block must name the runtime release. */
function verifyMovingVersionBlocks(path, source, version) {
  const blocks = source.matchAll(
    /x-release-please-start-version[^\n]*\n([\s\S]*?)x-release-please-end/gu,
  );
  let count = 0;
  for (const block of blocks) {
    count += 1;
    const versions = [...block[1].matchAll(/\b\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?\b/gu)].map(
      (match) => match[0],
    );
    if (versions.length === 0 || versions.some((candidate) => candidate !== version)) {
      fail(`${path} has a moving version block that does not exclusively name ${version}`);
    }
  }
  if (count === 0 && !source.includes("x-release-please-version")) {
    fail(`${path} has no complete generic version marker block`);
  }
}

/** Requires the migration's supported secondary messages plus the parent perf entry. */
function verifyInitialNotes() {
  const message = read("tools/fixtures/changes/migration.txt");
  if (!/^Release-As: 0\.5\.0$/mu.test(message))
    fail("migration does not force the first 0.5.0 release");

  const paragraphs = message.trim().split(/\n\s*\n/u);
  const breaking = paragraphs
    .filter((paragraph) => /^BREAKING CHANGE:/u.test(paragraph))
    .map((paragraph) => paragraph.replace(/^BREAKING CHANGE:\s*/u, "").replace(/\s+/gu, " "));
  const features = paragraphs.filter((paragraph) => /^feat(?:\([^)]*\))?:/u.test(paragraph));
  const expectedBreaking = [
    "Rename the graph mutation primitive from commit to turn; the old spellings are removed.",
    "Use automatic for non-manual cogs throughout Cog and CogTesting; the old derived spellings are removed.",
    "Remove Cogs.valueReferenceLayoutName and the retired generic and interned layout selectors from CogTesting.",
  ];
  requireEqual(
    JSON.stringify(breaking),
    JSON.stringify(expectedBreaking),
    "initial breaking notes",
  );
  requireEqual(
    JSON.stringify(features),
    JSON.stringify([
      "feat: rename the graph mutation primitive to turn",
      "feat: rename derived cogs to automatic cogs",
      "feat: remove the value-reference layout testing selector",
      "feat(swift): add the CompactArena package trait",
    ]),
    "initial feature notes",
  );
  const history = historyMessages();
  requireEqual(
    history.filter(
      (entry) =>
        entry.message.split("\n", 1)[0] === "perf(swift): make specialized arena the default",
    ).length,
    1,
    "parent performance revision count",
  );
  const migrations = history.filter(
    (entry) =>
      entry.message.split("\n", 1)[0] ===
      "ci(release): adopt Release Please and Conventional Commits",
  );
  requireEqual(migrations.length, 1, "migration revision count");
  requireEqual(migrations[0].message, message.trimEnd(), "migration revision secondary messages");

  const bootstrapWindow = history.slice(0, history.indexOf(migrations[0]) + 1);
  const recognizedSubjects = bootstrapWindow
    .map((entry) => entry.message.split("\n", 1)[0])
    .filter((subject) =>
      /^(?:build|chore|ci|docs|feat|fix|perf|refactor|revert|style|test)(?:\([^)]*\))?!?:/u.test(
        subject,
      ),
    );
  requireEqual(
    JSON.stringify(recognizedSubjects),
    JSON.stringify([
      "perf(swift): make specialized arena the default",
      "ci(release): adopt Release Please and Conventional Commits",
    ]),
    "post-bootstrap Conventional Commit subjects",
  );
}

/** Reads post-bootstrap history from jj locally and Git in authoritative CI checkouts. */
function historyMessages() {
  if (existsSync(join(REPO_ROOT, ".jj"))) {
    return collectJjRevisions(REPO_ROOT, `${BOOTSTRAP_SHA}..@`);
  }
  return collectGitCommits(REPO_ROOT, BOOTSTRAP_SHA, "HEAD");
}

/** Published sections remain singular; before release there is no hand-written 0.5.0 draft. */
function verifyChangelogState(version) {
  const changelog = read("CHANGELOG.md");
  if (changelog.includes("## [Unreleased]"))
    fail("CHANGELOG.md still has a hand-written Unreleased section");
  for (const version of ["0.4.0", "0.3.0", "0.1.0"]) {
    const matches = changelog.match(
      new RegExp(`^## \\[${version.replaceAll(".", "\\.")}\\]`, "gmu"),
    );
    if (matches?.length !== 1)
      fail(`published ${version} changelog entry was removed or duplicated`);
  }
  const publishedOffset = changelog.indexOf("## [0.4.0]");
  const publishedHash = createHash("sha256").update(changelog.slice(publishedOffset)).digest("hex");
  requireEqual(publishedHash, PUBLISHED_CHANGELOG_SHA256, "published changelog bytes");
  const firstRelease =
    changelog.match(/^## (?:\[0\.5\.0\]|0\.5\.0)[^\n]*\n[\s\S]*?(?=^## \[0\.4\.0\])/mu)?.[0] ??
    null;
  if (version === "0.4.0") {
    if (firstRelease !== null)
      fail("0.5.0 notes were committed before Release Please generated them");
    return;
  }
  if (firstRelease === null)
    fail("Release Please state is missing the first 0.5.0 changelog section");

  const expectedChanges = [
    "Rename the graph mutation primitive from commit to turn",
    "Use automatic for non-manual cogs throughout Cog and CogTesting",
    "Remove Cogs.valueReferenceLayoutName",
    "CompactArena package trait",
    "specialized arena the default",
  ];
  for (const change of expectedChanges) {
    if (!firstRelease.toLowerCase().includes(change.toLowerCase())) {
      fail(`the generated 0.5.0 notes omit ${JSON.stringify(change)}`);
    }
  }
}

function compareVersions(left, right) {
  const leftParts = left.split(/[.+-]/u, 3).map(Number);
  const rightParts = right.split(/[.+-]/u, 3).map(Number);
  for (let index = 0; index < 3; index += 1) {
    if (leftParts[index] !== rightParts[index]) return leftParts[index] - rightParts[index];
  }
  return 0;
}

function read(path, required = true) {
  try {
    return readFileSync(join(REPO_ROOT, path), "utf8");
  } catch (error) {
    if (!required && error.code === "ENOENT") return null;
    throw error;
  }
}

function json(path) {
  return JSON.parse(read(path));
}

function requireEqual(actual, expected, label) {
  if (actual !== expected)
    fail(`${label} is ${JSON.stringify(actual)}, expected ${JSON.stringify(expected)}`);
}

function fail(message) {
  console.error(`error: test-release-configuration: ${message}`);
  process.exit(1);
}
