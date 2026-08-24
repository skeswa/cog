#!/usr/bin/env node

// Runs the separate Storefront workload package's tests with the guards
// SwiftPM does not provide itself.
//
// The reasoning is the same one `swift-lint-test.mjs` records for the CogLint
// package: SwiftPM exits 0 when a filter selects nothing, so a filtered run can
// report a green for work it never did. Every run here enumerates the built
// tests first, requires every filter alternative to match something, owns its
// own xUnit report, and rejects an authoritative executed count of zero.
//
// This package matters more than most: its suite is the correctness gate every
// Storefront benchmark number rests on. A benchmark cut calls
// `requireCheckpointsHold()` before it reports, so a workload that computed the
// wrong answer traps instead of producing a timing — but only these tests say
// *which* claim broke, and only they run the trace under a debugger-friendly
// build.
//
// Usage: `storefront-test.mjs [swift test arguments...]`

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
const STOREFRONT_PACKAGE = join(
  REPO_ROOT,
  "swift",
  "Benchmarks",
  "Macro",
  "Storefront",
  "Workload",
);

/**
 * What the guards call the thing they are guarding.
 *
 * The package name, not a target name: `cog-storefront` builds two test
 * targets — `StorefrontWorkloadTests` for the runtime-neutral half and
 * `CogStorefrontTests` for the Cog half — and the guards count executed tests
 * across every xUnit file in the report directory, so they speak for both. A
 * literal one-target name here would name half the run in a message about all
 * of it, which is exactly the kind of misdirection a guard exists to avoid.
 */
const SUBJECT = "cog-storefront";

/**
 * A scratch path of its own, under the repository's ignored `.build`.
 *
 * Shared with nothing: this package resolves the root Cog package by path, so
 * it compiles Cog itself, and letting that share a scratch directory with the
 * root package's own test builds would make each invalidate the other.
 */
const SCRATCH_PATH = join(REPO_ROOT, ".build", "storefront");

main(process.argv.slice(2));

/** Enumerates, executes, and authoritatively counts one Storefront test run. */
function main(passthrough) {
  if (passthrough.some(isXUnitArgument)) {
    fail("`--xunit-output` is reserved for the wrapper's executed-test count");
  }

  const filters = extractFilters(passthrough, fail);
  const common = ["-c", "debug", "--scratch-path", SCRATCH_PATH];

  console.log(`\n==> swift test [${SUBJECT}] [debug]`);

  const listed = spawnSync("swift", ["test", "list", ...common], {
    cwd: STOREFRONT_PACKAGE,
    encoding: "utf8",
    stdio: ["inherit", "pipe", "inherit"],
  });
  exitOnFailure(listed, "swift test list");

  const specifiers = parseSpecifiers(listed.stdout);
  if (specifiers.length === 0) {
    fail(`${SUBJECT} lists zero tests, so the test run was refused`);
  }
  assertFiltersSelectTests(filters, specifiers, SUBJECT, fail);

  const reportDirectory = mkdtempSync(join(tmpdir(), "cog-storefront-test-"));
  process.on("exit", () => rmSync(reportDirectory, { force: true, recursive: true }));
  const reportPath = join(reportDirectory, "results.xml");

  const tested = spawnSync(
    "swift",
    ["test", ...common, "--xunit-output", reportPath, ...passthrough],
    {
      cwd: STOREFRONT_PACKAGE,
      stdio: "inherit",
    },
  );
  exitOnFailure(tested, "swift test");

  const executed = assertRunSelectedTests(filters, reportDirectory, SUBJECT, fail, {
    requireReport: true,
  });
  console.log(`==> ${SUBJECT} authoritative executed-test count: ${executed}`);
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
    console.error(`error: \`${what}\` failed for ${SUBJECT}`);
    process.exit(result.status);
  }
}

/** Reports a wrapper-level failure and exits nonzero. */
function fail(message) {
  console.error(`error: storefront-test: ${message}`);
  process.exit(1);
}
