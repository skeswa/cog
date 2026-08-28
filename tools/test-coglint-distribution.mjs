#!/usr/bin/env node

// Proves Channel B keeps ordinary Cog consumers free of linter sources and
// artifact fetches while preserving the measured eager-fetch boundary.

import { cpSync, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import {
  ARCHIVE_NAME,
  COGLINT_PLUGINS,
  PLUGINS_PACKAGE_NAME,
  makeRunners,
  pluginSourcePath,
  releaseArtifactURL,
} from "./lib/coglint-artifact.mjs";
import { shippingManifestEnvironment } from "./lib/cog-environment.mjs";
import { currentVersion } from "./lib/version.mjs";

/** The repository root and stable ignored LINT-20 scratch space. */
const REPO_ROOT = fileURLToPath(new URL("..", import.meta.url));
const TEST_ROOT = join(REPO_ROOT, ".build", "coglint-distribution");

/** Distribution identities that must never enter an ordinary Cog graph. */
const PACKAGE_NAME = PLUGINS_PACKAGE_NAME;
const ASSET_NAME = ARCHIVE_NAME;
const SOURCE_DEPENDENCIES = ["swift-syntax", "swift-argument-parser"];
const DUMMY_CHECKSUM = "0".repeat(64);
const VERSION = currentVersion();

const { runCaptured, runSuccessful } = makeRunners(fail);

main();

/** Generates Channel B and proves both sides of its fetch boundary. */
function main() {
  rmSync(TEST_ROOT, { force: true, recursive: true });
  mkdirSync(TEST_ROOT, { recursive: true });
  const distribution = generateDistribution();
  validateDistribution(distribution);
  verifyOrdinaryConsumer(distribution);
  verifyUnusedOptInStillFetches(distribution);
  if (existsSync(join(REPO_ROOT, "Package.resolved"))) {
    fail("LINT-20 left a root Package.resolved behind");
  }
  console.log(
    "\nPASS LINT-20: Channel B isolated ordinary Cog consumers and retained eager opt-in fetching",
  );
}

/** Runs the real generator with an inert checksum and the accepted release URL. */
function generateDistribution() {
  const output = join(TEST_ROOT, PACKAGE_NAME);
  runSuccessful(
    process.execPath,
    [
      join(REPO_ROOT, "tools", "generate-coglint-plugins.mjs"),
      "--version",
      VERSION,
      "--output",
      output,
      "--checksum",
      DUMMY_CHECKSUM,
    ],
    {},
  );
  return output;
}

/** Requires the exact generated products, targets, pins, and source copies. */
function validateDistribution(distribution) {
  const dumped = runSuccessful(
    "swift",
    ["package", "--package-path", distribution, "dump-package"],
    { encoding: "utf8" },
  );
  const manifest = JSON.parse(dumped.stdout);
  if (manifest.name !== PACKAGE_NAME || manifest.dependencies.length !== 0) {
    fail("generated package identity or zero-source-dependency contract drifted");
  }
  const products = manifest.products.map((product) => product.name).sort();
  if (
    JSON.stringify(products) !== JSON.stringify(["CogLintBuildToolPlugin", "CogLintCommandPlugin"])
  ) {
    fail(`unexpected generated products: ${products.join(", ")}`);
  }
  const targets = manifest.targets.map((target) => target.name).sort();
  if (
    JSON.stringify(targets) !==
    JSON.stringify(["CogLintBinary", "CogLintBuildToolPlugin", "CogLintCommandPlugin"])
  ) {
    fail(`unexpected generated targets: ${targets.join(", ")}`);
  }

  const record = JSON.parse(readFileSync(join(distribution, ".coglint-generation.json"), "utf8"));
  const expectedURL = releaseArtifactURL(VERSION);
  if (record.artifactURL !== expectedURL || record.checksum !== DUMMY_CHECKSUM) {
    fail("generated release record does not match its version, URL, and checksum inputs");
  }

  for (const plugin of COGLINT_PLUGINS) {
    const generated = readFileSync(
      join(distribution, "Plugins", plugin.name, "plugin.swift"),
      "utf8",
    );
    const source = readFileSync(pluginSourcePath(plugin.name), "utf8");
    if (generated !== source) {
      fail(`${plugin.name} distribution source differs from its repository owner`);
    }
  }
}

/** Resolves and builds a source-only consumer with no artifact request in its logs or graph. */
function verifyOrdinaryConsumer(distribution) {
  const consumer = join(TEST_ROOT, "OrdinaryConsumer");
  const sourceDirectory = join(consumer, "Sources", "Consumer");
  mkdirSync(sourceDirectory, { recursive: true });
  writeFileSync(
    join(sourceDirectory, "Consumer.swift"),
    "import Cog\npublic enum ConsumerMarker {}\n",
  );
  writeFileSync(
    join(consumer, "Package.swift"),
    `// swift-tools-version:6.2

import PackageDescription

let package = Package(
  name: "OrdinaryConsumer",
  platforms: [.macOS(.v14)],
  dependencies: [.package(path: ${JSON.stringify(REPO_ROOT)})],
  targets: [
    .target(
      name: "Consumer",
      dependencies: [.product(name: "Cog", package: "cog")]
    ),
  ]
)
`,
  );

  console.log("\n==> Ordinary Cog consumer resolve and build");
  const resolveResult = runSuccessful(
    "swift",
    [
      "package",
      "--package-path",
      consumer,
      "--scratch-path",
      join(consumer, ".build"),
      "resolve",
      "-v",
    ],
    { encoding: "utf8", env: cleanEnvironment() },
  );
  const buildResult = runSuccessful(
    "swift",
    ["build", "--package-path", consumer, "--scratch-path", join(consumer, ".build")],
    { encoding: "utf8", env: cleanEnvironment() },
  );
  const logs = `${resolveResult.stdout}\n${resolveResult.stderr}\n${buildResult.stdout}\n${buildResult.stderr}`;
  for (const forbidden of [
    PACKAGE_NAME,
    ASSET_NAME,
    "Downloading binary artifact",
    ...SOURCE_DEPENDENCIES,
  ]) {
    if (logs.toLowerCase().includes(forbidden.toLowerCase())) {
      fail(`ordinary consumer logs unexpectedly mention ${forbidden}`);
    }
  }

  const graphResult = runSuccessful(
    "swift",
    [
      "package",
      "--package-path",
      consumer,
      "--scratch-path",
      join(consumer, ".build"),
      "show-dependencies",
      "--format",
      "json",
    ],
    { encoding: "utf8", env: cleanEnvironment() },
  );
  const graphText = graphResult.stdout.toLowerCase();
  for (const forbidden of [PACKAGE_NAME, ...SOURCE_DEPENDENCIES]) {
    if (graphText.includes(forbidden.toLowerCase())) {
      fail(`ordinary consumer dependency graph unexpectedly contains ${forbidden}`);
    }
  }
  const identities = dependencyIdentities(JSON.parse(graphResult.stdout)).sort();
  if (JSON.stringify(identities) !== JSON.stringify(["cog", "ordinaryconsumer"])) {
    fail(`ordinary consumer graph contains unexpected identities: ${identities.join(", ")}`);
  }
  console.log("==> Ordinary graph contains Cog only; no lint fetch or source dependency appeared");

  if (!existsSync(distribution)) {
    fail("distribution fixture disappeared while proving it was outside the ordinary graph");
  }
}

/** Flattens SwiftPM dependency identities for an exact graph-boundary assertion. */
function dependencyIdentities(node) {
  return [node.identity, ...(node.dependencies ?? []).flatMap(dependencyIdentities)];
}

/** Replays the measured eager fetch when a consumer opts into even an unused sibling. */
function verifyUnusedOptInStillFetches(distribution) {
  const fixtureDistribution = join(TEST_ROOT, "UnreachableCogLintPlugins");
  cpSync(distribution, fixtureDistribution, { recursive: true });
  const manifestPath = join(fixtureDistribution, "Package.swift");
  const realURL = releaseArtifactURL(VERSION);
  const unreachableURL = `https://127.0.0.1:1/${ASSET_NAME}`;
  const manifest = readFileSync(manifestPath, "utf8").replace(realURL, unreachableURL);
  if (!manifest.includes(unreachableURL)) {
    fail("could not install the unreachable artifact sentinel");
  }
  writeFileSync(manifestPath, manifest);

  const consumer = join(TEST_ROOT, "UnusedOptInConsumer");
  const sourceDirectory = join(consumer, "Sources", "Unused");
  mkdirSync(sourceDirectory, { recursive: true });
  writeFileSync(join(sourceDirectory, "Unused.swift"), "public enum UnusedMarker {}\n");
  writeFileSync(
    join(consumer, "Package.swift"),
    `// swift-tools-version:6.2

import PackageDescription

let package = Package(
  name: "UnusedOptInConsumer",
  dependencies: [.package(path: ${JSON.stringify(fixtureDistribution)})],
  targets: [.target(name: "Unused")]
)
`,
  );

  console.log("\n==> Unused Channel B opt-in eager-fetch sentinel");
  const result = runCaptured(
    "swift",
    [
      "package",
      "--package-path",
      consumer,
      "--scratch-path",
      join(consumer, ".build"),
      "resolve",
      "-v",
    ],
    { encoding: "utf8", env: cleanEnvironment() },
  );
  const output = `${result.stdout}\n${result.stderr}`;
  if (
    result.status === 0 ||
    !output.includes(unreachableURL) ||
    !output.includes("Downloading binary artifact")
  ) {
    fail("unused plugin-package opt-in did not reproduce eager artifact fetching");
  }
  console.log("==> Unused opt-in attempted the unreachable binary exactly as measured");
}

/** Removes manifest selectors so the ordinary graph uses Cog shipping defaults. */
function cleanEnvironment() {
  return shippingManifestEnvironment(process.env);
}

/** Reports a distribution-boundary failure without publishing generated output. */
function fail(message) {
  console.error(`error: CogLint distribution test: ${message}`);
  process.exit(1);
}
