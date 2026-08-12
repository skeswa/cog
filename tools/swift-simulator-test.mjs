#!/usr/bin/env node

// Runs only CogBoundaryTests on the current Xcode's latest iOS simulator.
//
// Swift Testing exit tests are unavailable on iOS. Xcode's generated package
// scheme nevertheless builds every test target before applying
// `-only-testing`, so Package.swift uses COG_SIMULATOR_BOUNDARY_ONLY to omit
// the host-only targets from this one build. The selection remains explicit
// on the xcodebuild invocation as a second guard against broadening the lane.

import { spawnSync } from "node:child_process";
import { rmSync } from "node:fs";
import { fileURLToPath } from "node:url";

const REPO_ROOT = fileURLToPath(new URL("..", import.meta.url));
const RESULT_BUNDLE = ".build/simulator-results.xcresult";
const destination =
  process.env.COG_SIMULATOR_DESTINATION ?? "platform=iOS Simulator,OS=latest,name=iPhone 17 Pro";

console.log(`\n==> xcodebuild test [CogBoundaryTests] [${destination}]`);
rmSync(`${REPO_ROOT}/${RESULT_BUNDLE}`, { force: true, recursive: true });

const result = spawnSync(
  "xcodebuild",
  [
    "test",
    "-quiet",
    "-scheme",
    "cog-Package",
    "-destination",
    destination,
    "-only-testing:CogBoundaryTests",
    "-derivedDataPath",
    ".build/simulator-derived-data",
    "-resultBundlePath",
    RESULT_BUNDLE,
    "CODE_SIGNING_ALLOWED=NO",
  ],
  {
    cwd: REPO_ROOT,
    env: {
      ...process.env,
      COG_SIMULATOR_BOUNDARY_ONLY: "1",
      COG_TEST_ISOLATION: "mainactor",
      COG_TEST_NNBD: "1",
    },
    stdio: "inherit",
  },
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
if (bundles.length !== 1 || bundles[0] !== "CogBoundaryTests") {
  fail(`expected only CogBoundaryTests, found ${bundles.join(", ") || "no test bundle"}`);
}
console.log(`simulator tests: OK CogBoundaryTests — ${tests} test(s)`);

function visit(nodes) {
  for (const node of nodes) {
    if (node.nodeType === "Unit test bundle") bundles.push(node.name);
    if (node.nodeType === "Test Case") tests += 1;
    visit(node.children ?? []);
  }
}

function fail(message) {
  console.error(`error: ${message}`);
  process.exit(1);
}
