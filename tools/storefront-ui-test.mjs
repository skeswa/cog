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
// This wrapper does not trust the exit status alone — `lib/xcresult.mjs`
// reads the result bundle back and requires a non-zero executed count from
// the one **UI** test bundle it expects.
//
// Usage: `storefront-ui-test.mjs [extra xcodebuild arguments...]`
// Set `COG_STOREFRONT_DESTINATION` to override the simulator destination.

import { spawnSync } from "node:child_process";
import { rmSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { assertExactBundleExecuted } from "./lib/xcresult.mjs";

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

const tests = assertExactBundleExecuted(RESULT_BUNDLE, {
  bundleName: BUNDLE_NAME,
  kind: "ui",
  cwd: REPO_ROOT,
  fail,
});
console.log(`storefront ui tests: OK ${BUNDLE_NAME} — ${tests} test(s)`);

/** Reports a wrapper-level failure and exits nonzero. */
function fail(message) {
  console.error(`error: storefront-ui-test: ${message}`);
  process.exit(1);
}
