#!/usr/bin/env node

// Runs the Storefront benchmark application's XCUIAutomation suite on an iOS
// simulator, in **release**, and then proves it actually ran.
//
// Release is not a detail. Apple's performance-test guidance is explicit that a
// measured run builds for testing with the Release configuration, with the
// debugger, code coverage, and every runtime diagnostic disabled; the scheme
// carries those settings and this wrapper carries the configuration. A debug
// measurement of a SwiftUI app measures the optimizer's absence, exactly as a
// debug benchmark of the graph would.
//
// This wrapper does not trust the exit status alone — it reads the result
// bundle back and requires a non-zero executed count from the one bundle it
// expects. A **UI** test bundle reports `nodeType` as `"UI test bundle"`, not
// `"Unit test bundle"`, so the result parser must distinguish the two.
//
// Usage: `storefront-ui-test.mjs [extra xcodebuild arguments...]`
// Set `COG_STOREFRONT_DESTINATION` to override the simulator destination.

import { spawnSync } from "node:child_process";
import { rmSync } from "node:fs";
import { fileURLToPath } from "node:url";

const REPO_ROOT = fileURLToPath(new URL("..", import.meta.url));
const PROJECT = "swift/Benchmarks/Storefront/Apps/Cog/Storefront.xcodeproj";
const SCHEME = "StorefrontBench";
const BUNDLE_NAME = "StorefrontUITests";
const RESULT_BUNDLE = ".build/storefront-uitest-results.xcresult";

/**
 * The pinned destination.
 *
 * One device, one OS, and no "any iOS Simulator": the visible row count, the
 * row height, and the hitch measurements are only comparable across runs if the
 * screen they were measured on is the same screen. An override exists for local
 * exploration and is not what CI uses.
 */
const destination =
  process.env.COG_STOREFRONT_DESTINATION ?? "platform=iOS Simulator,OS=latest,name=iPhone 17 Pro";

const passthrough = process.argv.slice(2);

console.log(`\n==> xcodebuild test [${BUNDLE_NAME}] [Release] [${destination}]`);
rmSync(`${REPO_ROOT}/${RESULT_BUNDLE}`, { force: true, recursive: true });

const result = spawnSync(
  "xcodebuild",
  [
    "test",
    "-quiet",
    "-project",
    PROJECT,
    "-scheme",
    SCHEME,
    "-configuration",
    "Release",
    "-destination",
    destination,
    "-only-testing:" + BUNDLE_NAME,
    "-derivedDataPath",
    ".build/storefront-uitest-derived-data",
    "-resultBundlePath",
    RESULT_BUNDLE,
    "CODE_SIGNING_ALLOWED=NO",
    ...passthrough,
  ],
  { cwd: REPO_ROOT, stdio: "inherit" },
);

if (result.error !== undefined) throw result.error;
if (result.status !== 0) process.exit(result.status ?? 1);

const inspected = spawnSync(
  "xcrun",
  ["xcresulttool", "get", "test-results", "tests", "--path", RESULT_BUNDLE, "--compact"],
  { cwd: REPO_ROOT, encoding: "utf8" },
);
if (inspected.error !== undefined) throw inspected.error;
if (inspected.status !== 0) {
  process.stderr.write(inspected.stderr);
  process.exit(inspected.status ?? 1);
}

const report = JSON.parse(inspected.stdout);
const bundles = [];
let tests = 0;
visit(report.testNodes ?? []);
if (tests === 0) fail("xcodebuild completed without executing a test");
if (bundles.length !== 1 || bundles[0] !== BUNDLE_NAME) {
  fail(`expected only ${BUNDLE_NAME}, found ${bundles.join(", ") || "no test bundle"}`);
}
console.log(`storefront ui tests: OK ${BUNDLE_NAME} — ${tests} test(s)`);

/** Walks the result-bundle tree, collecting bundle names and counting cases. */
function visit(nodes) {
  for (const node of nodes) {
    // `"UI test bundle"`, not `"Unit test bundle"`. See the note at the top.
    if (node.nodeType === "UI test bundle") bundles.push(node.name);
    if (node.nodeType === "Test Case") tests += 1;
    visit(node.children ?? []);
  }
}

/** Reports a wrapper-level failure and exits nonzero. */
function fail(message) {
  console.error(`error: storefront-ui-test: ${message}`);
  process.exit(1);
}
