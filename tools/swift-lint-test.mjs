#!/usr/bin/env node

// Runs the separate CogLint package's tests with guards SwiftPM does not
// provide itself. SwiftPM exits 0 when a filter selects nothing, so every run
// enumerates the built tests first and every filter alternative must match.
// The wrapper also owns an xUnit report for every invocation, requires the
// report to exist, and rejects an authoritative executed count of zero.
//
// Usage: `swift-lint-test.mjs [swift test arguments...]`

import { spawnSync } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import {
  assertFiltersSelectTests,
  assertRunSelectedTests,
  extractFilters,
  isXUnitArgument,
  parseSpecifiers,
} from "./lib/swift-test-guard.mjs";

/** The repository root, resolved from this file so cwd never matters. */
const REPO_ROOT = fileURLToPath(new URL("..", import.meta.url));

/** The separate package whose build graph and tests this wrapper owns. */
const LINT_PACKAGE = join(REPO_ROOT, "swift", "Lint");

main(process.argv.slice(2));

/** Enumerates, executes, and authoritatively counts one CogLint test run. */
function main(passthrough) {
  if (passthrough.some(isXUnitArgument)) {
    fail("`--xunit-output` is reserved for the wrapper's executed-test count");
  }

  const filters = extractFilters(passthrough, fail);
  const common = ["-c", "debug", "--scratch-path", ".build/tests-debug"];

  console.log("\n==> swift test [CogLint] [debug]");

  const listed = spawnSync("swift", ["test", "list", ...common], {
    cwd: LINT_PACKAGE,
    encoding: "utf8",
    stdio: ["inherit", "pipe", "inherit"],
  });
  exitOnFailure(listed, "swift test list");

  const specifiers = parseSpecifiers(listed.stdout);
  if (specifiers.length === 0) {
    fail("CogLint lists zero tests, so the test run was refused");
  }
  assertFiltersSelectTests(filters, specifiers, "CogLint", fail);

  const reportDirectory = mkdtempSync(join(tmpdir(), "cog-lint-test-"));
  process.on("exit", () => rmSync(reportDirectory, { force: true, recursive: true }));
  const reportPath = join(reportDirectory, "results.xml");

  const tested = spawnSync(
    "swift",
    ["test", ...common, "--xunit-output", reportPath, ...passthrough],
    {
      cwd: LINT_PACKAGE,
      stdio: "inherit",
    },
  );
  exitOnFailure(tested, "swift test");

  const executed = assertRunSelectedTests(filters, reportDirectory, "CogLint", fail, {
    requireReport: true,
  });
  console.log(`==> CogLint authoritative executed-test count: ${executed}`);
}

/** Propagates a child process failure, including death by signal. */
function exitOnFailure(result, what) {
  if (result.error !== undefined) {
    fail(`could not run \`${what}\`: ${result.error.message}`);
  }
  if (result.signal !== null && result.signal !== undefined) {
    fail(`\`${what}\` was killed by ${result.signal}`);
  }
  if (result.status !== 0) {
    console.error(`error: \`${what}\` failed for CogLint`);
    process.exit(result.status);
  }
}

/** Reports a wrapper-level failure and exits nonzero. */
function fail(message) {
  console.error(`error: swift-lint-test: ${message}`);
  process.exit(1);
}
