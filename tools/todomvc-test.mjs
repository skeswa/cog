#!/usr/bin/env node

// Runs the TodoMVC example's own test target on an iOS simulator.
//
// `mise run build:todomvc` uses xcodebuild's `build` action, and the TodoMVC
// scheme lists only `TodoMVC.app` under its build action — `TodoMVCTests`
// appears solely under the test action. A plain build therefore never even
// compiles the tests, so the example's behaviour proofs need this second
// command to run at all.
//
// Like tools/swift-test.mjs, this wrapper does not trust the exit status
// alone. TodoMVC's test sources are wrapped in `#if DEBUG` because their
// isolated seeding capabilities are debug-only, so a configuration mistake
// would silently shrink the suite instead of failing it.
// The result bundle is inspected afterwards for a non-zero executed count and
// for `TodoMVCTests` as the only bundle that ran.

import { spawnSync } from "node:child_process";
import { rmSync } from "node:fs";
import { fileURLToPath } from "node:url";

const REPO_ROOT = fileURLToPath(new URL("..", import.meta.url));
const PROJECT = "swift/Examples/TodoMVC/TodoMVC.xcodeproj";
const RESULT_BUNDLE = ".build/todomvc-results.xcresult";
const destination =
  process.env.COG_TODOMVC_DESTINATION ?? "platform=iOS Simulator,OS=latest,name=iPhone 17 Pro";

console.log(`\n==> xcodebuild test [TodoMVCTests] [${destination}]`);
rmSync(`${REPO_ROOT}/${RESULT_BUNDLE}`, { force: true, recursive: true });

const result = spawnSync(
  "xcodebuild",
  [
    "test",
    "-quiet",
    "-project",
    PROJECT,
    "-scheme",
    "TodoMVC",
    "-configuration",
    "Debug",
    "-destination",
    destination,
    "-derivedDataPath",
    ".build/todomvc-test-derived-data",
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
if (bundles.length !== 1 || bundles[0] !== "TodoMVCTests") {
  fail(`expected only TodoMVCTests, found ${bundles.join(", ") || "no test bundle"}`);
}
console.log(`todomvc tests: OK TodoMVCTests — ${tests} test(s)`);

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
