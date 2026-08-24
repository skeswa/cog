#!/usr/bin/env node

// Runs the cross-runtime Storefront agreement suite with the guards SwiftPM
// does not provide itself.
//
// This is the strongest correctness gate the Storefront macrobenchmark has: it
// links all four runtimes — the Cog port, the raw `@Observable` floor, the
// hand-memoized `@Observable` port, and the swift-state-graph port — and proves
// they computed the *same answers* before any timing between them is allowed to
// mean anything. Without it a fast number might simply be a wrong number.
//
// The suite lives in `swift/Benchmarks` because there is nowhere else it could.
// `cog-storefront` cannot see the ports; the two port packages cannot see each
// other, deliberately, since target separation is what makes it a compile error
// for one port to reach into another's cache. The benchmark package already
// depends on all four, so it is the one place the four coexist without weakening
// that separation.
//
// The guards matter more here than anywhere: SwiftPM exits 0 when a filter
// selects nothing, so an empty run would report agreement that was never
// checked. Every run enumerates the built tests first, requires every filter
// alternative to match something, owns its own xUnit report, and rejects an
// authoritative executed count of zero.
//
// Usage: `storefront-agreement-test.mjs [swift test arguments...]`

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

/** The separate benchmark package that hosts the agreement suite. */
const BENCHMARKS_PACKAGE = join(REPO_ROOT, "swift", "Benchmarks");

/**
 * What the guards call the thing they are guarding.
 *
 * The package name plus the suite, because `cog-benchmarks` also holds the
 * benchmark executable and `swift package benchmark` is a different command
 * entirely. A message that named only the package would leave a reader guessing
 * which of the two failed.
 */
const SUBJECT = "cog-benchmarks (cross-runtime agreement)";

/**
 * A scratch path of its own, under the repository's ignored `.build`.
 *
 * Shared with nothing, and in particular not with `swift/Benchmarks/.build`,
 * which `mise run bench` uses. A measured run and a test run compile the same
 * package under different configurations and different traits; letting them
 * share a scratch directory would make each invalidate the other, and a
 * benchmark that had to rebuild the world before every sample is a benchmark
 * nobody runs.
 */
const SCRATCH_PATH = join(REPO_ROOT, ".build", "storefront-agreement");

main(process.argv.slice(2));

/** Enumerates, executes, and authoritatively counts one agreement-suite run. */
function main(passthrough) {
  if (passthrough.some(isXUnitArgument)) {
    fail("`--xunit-output` is reserved for the wrapper's executed-test count");
  }

  const filters = extractFilters(passthrough, fail);
  const common = ["-c", "debug", "--scratch-path", SCRATCH_PATH];

  console.log(`\n==> swift test [${SUBJECT}] [debug]`);

  const listed = spawnSync("swift", ["test", "list", ...common], {
    cwd: BENCHMARKS_PACKAGE,
    encoding: "utf8",
    stdio: ["inherit", "pipe", "inherit"],
  });
  exitOnFailure(listed, "swift test list");

  const specifiers = parseSpecifiers(listed.stdout);
  if (specifiers.length === 0) {
    fail(`${SUBJECT} lists zero tests, so the test run was refused`);
  }
  assertFiltersSelectTests(filters, specifiers, SUBJECT, fail);

  const reportDirectory = mkdtempSync(join(tmpdir(), "cog-storefront-agreement-test-"));
  process.on("exit", () => rmSync(reportDirectory, { force: true, recursive: true }));
  const reportPath = join(reportDirectory, "results.xml");

  const tested = spawnSync(
    "swift",
    ["test", ...common, "--xunit-output", reportPath, ...passthrough],
    {
      cwd: BENCHMARKS_PACKAGE,
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
  console.error(`error: storefront-agreement-test: ${message}`);
  process.exit(1);
}
