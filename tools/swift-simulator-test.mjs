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
import { assertExactBundleExecuted } from "./lib/xcresult.mjs";

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

const tests = assertExactBundleExecuted(RESULT_BUNDLE, {
  bundleName: "CogBoundaryTests",
  kind: "unit",
  cwd: REPO_ROOT,
  fail,
});
console.log(`simulator tests: OK CogBoundaryTests — ${tests} test(s)`);

function fail(message) {
  console.error(`error: swift-simulator-test: ${message}`);
  process.exit(1);
}
