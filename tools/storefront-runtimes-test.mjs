#!/usr/bin/env node

// Runs the separate plain-Swift Storefront comparison-runtime package's tests
// with the guards SwiftPM does not provide itself.
//
// The reasoning is the one `storefront-test.mjs` records for the workload
// package, and it applies with more force here: SwiftPM exits 0 when a filter
// selects nothing, and this suite's whole job is to prove that two runtimes with
// no Cog in them produce the same shopping session Cog does. A silently empty
// run would report agreement that was never checked, and the benchmark numbers
// this package eventually publishes rest entirely on that agreement.
//
// Every run enumerates the built tests first, requires every filter alternative
// to match something, owns its own xUnit report, and rejects an authoritative
// executed count of zero.
//
// Usage: `storefront-runtimes-test.mjs [swift test arguments...]`

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
const RUNTIMES_PACKAGE = join(
  REPO_ROOT,
  "swift",
  "Benchmarks",
  "Storefront",
  "Runtimes",
  "Observation",
);

/**
 * What the guards call the thing they are guarding.
 *
 * The package name rather than a target name: `cog-storefront-observation` builds
 * one test target today but two library targets — `StorefrontObservationRaw` and
 * `StorefrontObservationMemo` — and the guards count executed tests across every
 * xUnit file in the report directory, so they speak for the whole package. A
 * literal one-target name here would name part of the run in a message about all
 * of it, which is exactly the kind of misdirection a guard exists to avoid.
 */
const SUBJECT = "cog-storefront-observation";

/**
 * A scratch path of its own, under the repository's ignored `.build`.
 *
 * Shared with nothing. This package resolves only the neutral workload, and a
 * scratch directory of its own keeps runtime builds from invalidating one
 * another even though they consume the same workload product.
 */
const SCRATCH_PATH = join(REPO_ROOT, ".build", "storefront-runtimes");

main(process.argv.slice(2));

/** Enumerates, executes, and authoritatively counts one comparison-runtime test run. */
function main(passthrough) {
  if (passthrough.some(isXUnitArgument)) {
    fail("`--xunit-output` is reserved for the wrapper's executed-test count");
  }

  const filters = extractFilters(passthrough, fail);
  const common = ["-c", "debug", "--scratch-path", SCRATCH_PATH];

  console.log(`\n==> swift test [${SUBJECT}] [debug]`);

  const listed = spawnSync("swift", ["test", "list", ...common], {
    cwd: RUNTIMES_PACKAGE,
    encoding: "utf8",
    stdio: ["inherit", "pipe", "inherit"],
  });
  exitOnFailure(listed, "swift test list");

  const specifiers = parseSpecifiers(listed.stdout);
  if (specifiers.length === 0) {
    fail(`${SUBJECT} lists zero tests, so the test run was refused`);
  }
  assertFiltersSelectTests(filters, specifiers, SUBJECT, fail);

  const reportDirectory = mkdtempSync(join(tmpdir(), "cog-storefront-runtimes-test-"));
  process.on("exit", () => rmSync(reportDirectory, { force: true, recursive: true }));
  const reportPath = join(reportDirectory, "results.xml");

  const tested = spawnSync(
    "swift",
    ["test", ...common, "--xunit-output", reportPath, ...passthrough],
    {
      cwd: RUNTIMES_PACKAGE,
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
  console.error(`error: storefront-runtimes-test: ${message}`);
  process.exit(1);
}
