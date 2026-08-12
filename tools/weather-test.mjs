#!/usr/bin/env node

// Runs the Weather example's own test target on an iOS simulator.
//
// `mise run build:weather` uses xcodebuild's `build` action, and the Weather
// scheme lists only `Weather.app` under its build action — `WeatherTests`
// appears solely under the test action. A plain build therefore never even
// compiles the tests, so the example's behaviour proofs need this second
// command to run at all.
//
// Like tools/swift-test.mjs, this wrapper does not trust the exit status
// alone. Both Weather test files are wrapped in `#if DEBUG` because the seams
// they need (`seedWeather`, `stubWeather`, `renderProbe`) are debug-only, so a
// configuration mistake would silently shrink the suite instead of failing it.
// The result bundle is inspected afterwards for a non-zero executed count and
// for `WeatherTests` as the only bundle that ran.

import { spawnSync } from "node:child_process";
import { rmSync } from "node:fs";
import { fileURLToPath } from "node:url";

const REPO_ROOT = fileURLToPath(new URL("..", import.meta.url));
const PROJECT = "swift/Examples/Weather/Weather.xcodeproj";
const RESULT_BUNDLE = ".build/weather-results.xcresult";
const destination =
  process.env.COG_WEATHER_DESTINATION ?? "platform=iOS Simulator,OS=latest,name=iPhone 17 Pro";

console.log(`\n==> xcodebuild test [WeatherTests] [${destination}]`);
rmSync(`${REPO_ROOT}/${RESULT_BUNDLE}`, { force: true, recursive: true });

const result = spawnSync(
  "xcodebuild",
  [
    "test",
    "-quiet",
    "-project",
    PROJECT,
    "-scheme",
    "Weather",
    "-configuration",
    "Debug",
    "-destination",
    destination,
    "-derivedDataPath",
    ".build/weather-test-derived-data",
    "-resultBundlePath",
    RESULT_BUNDLE,
    "CODE_SIGNING_ALLOWED=NO",
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
if (bundles.length !== 1 || bundles[0] !== "WeatherTests") {
  fail(`expected only WeatherTests, found ${bundles.join(", ") || "no test bundle"}`);
}
console.log(`weather tests: OK WeatherTests — ${tests} test(s)`);

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
