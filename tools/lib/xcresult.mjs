// The one reader of xcodebuild result bundles for the simulator test lanes.
//
// An xcodebuild exit status alone cannot prove a lane ran what it claims:
// `-only-testing` narrows a run silently, and a scheme change can move tests
// between bundles without failing anything. Each lane therefore reads its
// result bundle back and requires a non-zero executed count from exactly the
// one bundle it expects.
//
// The bundle kind is part of that expectation. A **UI** test bundle reports
// `nodeType` as `"UI test bundle"`, not `"Unit test bundle"`, so the walk
// collects both kinds and checks the kind alongside the name — a bundle of
// the wrong kind is named as a scope violation rather than disappearing into
// a "found no test bundle" message that reads as a harness fault.

import { spawnSync } from "node:child_process";

/** The `nodeType` value each lane kind expects its one bundle to report. */
const BUNDLE_NODE_TYPES = new Map([
  ["unit", "Unit test bundle"],
  ["ui", "UI test bundle"],
]);

/**
 * Reads a result bundle and requires one named bundle with executed tests.
 *
 * Exits through `fail` (or the inspection's own status) when the bundle
 * cannot be read, no test executed, or the executed bundles are not exactly
 * the expected one. Returns the executed-test count otherwise.
 *
 * @param {string} resultBundlePath Path of the `.xcresult` bundle, relative
 *   to `cwd`, written by the lane's `-resultBundlePath`.
 * @param {object} expectation
 * @param {string} expectation.bundleName The one test bundle the lane runs.
 * @param {"unit" | "ui"} expectation.kind The bundle kind that name must be.
 * @param {string} expectation.cwd Where `resultBundlePath` resolves from.
 * @param {(message: string) => never} expectation.fail The caller's reporter,
 *   so refusals carry the lane's name.
 */
export function assertExactBundleExecuted(resultBundlePath, { bundleName, kind, cwd, fail }) {
  const expectedNodeType = BUNDLE_NODE_TYPES.get(kind);
  if (expectedNodeType === undefined) {
    fail(`unknown result-bundle kind ${JSON.stringify(kind)}`);
  }

  const inspected = spawnSync(
    "xcrun",
    ["xcresulttool", "get", "test-results", "tests", "--path", resultBundlePath, "--compact"],
    { cwd, encoding: "utf8" },
  );
  if (inspected.error !== undefined) throw inspected.error;
  if (inspected.status !== 0) {
    process.stderr.write(inspected.stderr);
    process.exit(inspected.status ?? 1);
  }

  const bundles = [];
  let tests = 0;
  visit(JSON.parse(inspected.stdout).testNodes ?? []);

  if (tests === 0) fail("xcodebuild completed without executing a test");
  const expected =
    bundles.length === 1 &&
    bundles[0].name === bundleName &&
    bundles[0].nodeType === expectedNodeType;
  if (!expected) {
    const found = bundles.map((bundle) => `${bundle.name} (${bundle.nodeType})`).join(", ");
    fail(`expected only ${bundleName} (${expectedNodeType}), found ${found || "no test bundle"}`);
  }
  return tests;

  /** Walks the result-bundle tree, collecting bundle nodes and counting cases. */
  function visit(nodes) {
    for (const node of nodes) {
      if (node.nodeType === "Unit test bundle" || node.nodeType === "UI test bundle") {
        bundles.push({ name: node.name, nodeType: node.nodeType });
      }
      if (node.nodeType === "Test Case") tests += 1;
      visit(node.children ?? []);
    }
  }
}
