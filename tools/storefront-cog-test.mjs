#!/usr/bin/env node

// Runs the Cog Storefront runtime package's tests with the same nonempty-filter
// and authoritative executed-count guards as every other Swift package suite.

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

/** The package containing the Cog implementation and its correctness tests. */
const COG_STOREFRONT_PACKAGE = join(
  REPO_ROOT,
  "swift",
  "Benchmarks",
  "Storefront",
  "Runtimes",
  "CogRuntime",
);

/** The package name used in guard diagnostics. */
const SUBJECT = "cog-storefront";

/** A scratch path isolated from the workload and other runtime packages. */
const SCRATCH_PATH = join(REPO_ROOT, ".build", "storefront-cog");

main(process.argv.slice(2));

/** Enumerates, executes, and authoritatively counts one Cog runtime test run. */
function main(passthrough) {
  if (passthrough.some(isXUnitArgument)) {
    fail("`--xunit-output` is reserved for the wrapper's executed-test count");
  }

  const filters = extractFilters(passthrough, fail);
  const common = ["-c", "debug", "--scratch-path", SCRATCH_PATH];

  console.log(`\n==> swift test [${SUBJECT}] [debug]`);

  const listed = spawnSync("swift", ["test", "list", ...common], {
    cwd: COG_STOREFRONT_PACKAGE,
    encoding: "utf8",
    stdio: ["inherit", "pipe", "inherit"],
  });
  exitOnFailure(listed, "swift test list");

  const specifiers = parseSpecifiers(listed.stdout);
  if (specifiers.length === 0) {
    fail(`${SUBJECT} lists zero tests, so the test run was refused`);
  }
  assertFiltersSelectTests(filters, specifiers, SUBJECT, fail);

  const reportDirectory = mkdtempSync(join(tmpdir(), "cog-storefront-cog-test-"));
  process.on("exit", () => rmSync(reportDirectory, { force: true, recursive: true }));
  const reportPath = join(reportDirectory, "results.xml");

  const tested = spawnSync(
    "swift",
    ["test", ...common, "--xunit-output", reportPath, ...passthrough],
    {
      cwd: COG_STOREFRONT_PACKAGE,
      stdio: "inherit",
    },
  );
  exitOnFailure(tested, "swift test");

  const executed = assertRunSelectedTests(filters, reportDirectory, SUBJECT, fail, {
    requireReport: true,
  });
  console.log(`==> ${SUBJECT} authoritative executed-test count: ${executed}`);
}

/** Propagates a child-process failure, including death by signal. */
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

/** Fails without a stack trace, matching the other guarded test wrappers. */
function fail(message) {
  console.error(`error: ${message}`);
  process.exit(1);
}
