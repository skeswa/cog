// The one implementation of a guarded SwiftPM package test run.
//
// SwiftPM exits 0 when a filter selects nothing, so a filtered run can report
// a green for work it never did. Every guarded run therefore enumerates the
// built tests first, requires every filter alternative to match something,
// owns its own xUnit report, and rejects an authoritative executed count of
// zero. The per-package entry scripts in `tools/` record why their packages
// are guarded; this module is the single place the guarantee is implemented,
// and `test-guarded-package-test.mjs` proves its refusal paths against a fake
// `swift` executable.

import { spawnSync } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { basename, join } from "node:path";
import {
  assertFiltersSelectTests,
  assertRunSelectedTests,
  extractFilters,
  isXUnitArgument,
  parseSpecifiers,
} from "./swift-test-guard.mjs";

/**
 * The invoking entry script's name, so a failure names the command the caller
 * actually ran rather than this shared module.
 */
const ENTRY_NAME = basename(process.argv[1] ?? "guarded-package-test", ".mjs");

/**
 * Enumerates, executes, and authoritatively counts one package's test run.
 *
 * Exits the process on any failure: a reserved argument, an empty selection,
 * a failed child process, a missing report, or an executed count of zero.
 *
 * @param {object} configuration
 * @param {string} configuration.packagePath Absolute root of the SwiftPM
 *   package whose build graph and tests the caller owns.
 * @param {string} configuration.subject What guard diagnostics call the
 *   package. The package name rather than a target name: the guards count
 *   executed tests across every xUnit file in the report directory, so they
 *   speak for the whole package however many test targets it grows.
 * @param {string} configuration.scratchPath A `--scratch-path` shared with
 *   nothing else, so no other package's builds can invalidate this one.
 * @param {string[]} passthrough Extra `swift test` arguments from the caller,
 *   such as `--filter`.
 */
export function runGuardedPackageTests({ packagePath, subject, scratchPath }, passthrough) {
  if (passthrough.some(isXUnitArgument)) {
    fail("`--xunit-output` is reserved for the wrapper's executed-test count");
  }

  const filters = extractFilters(passthrough, fail);
  const common = ["-c", "debug", "--scratch-path", scratchPath];

  console.log(`\n==> swift test [${subject}] [debug]`);

  const listed = spawnSync("swift", ["test", "list", ...common], {
    cwd: packagePath,
    encoding: "utf8",
    stdio: ["inherit", "pipe", "inherit"],
  });
  exitOnFailure(listed, "swift test list", subject);

  const specifiers = parseSpecifiers(listed.stdout);
  if (specifiers.length === 0) {
    fail(`${subject} lists zero tests, so the test run was refused`);
  }
  assertFiltersSelectTests(filters, specifiers, subject, fail);

  const reportDirectory = mkdtempSync(join(tmpdir(), `${subject}-test-`));
  process.on("exit", () => rmSync(reportDirectory, { force: true, recursive: true }));
  const reportPath = join(reportDirectory, "results.xml");

  const tested = spawnSync(
    "swift",
    ["test", ...common, "--xunit-output", reportPath, ...passthrough],
    {
      cwd: packagePath,
      stdio: "inherit",
    },
  );
  exitOnFailure(tested, "swift test", subject);

  const executed = assertRunSelectedTests(filters, reportDirectory, subject, fail, {
    requireReport: true,
  });
  console.log(`==> ${subject} authoritative executed-test count: ${executed}`);
}

/** Propagates a child process failure, including death by signal. */
function exitOnFailure(result, what, subject) {
  if (result.error !== undefined) {
    fail(`could not run \`${what}\`: ${result.error.message}`);
  }
  if (result.signal !== null && result.signal !== undefined) {
    fail(`\`${what}\` was killed by ${result.signal}`);
  }
  if (result.status !== 0) {
    console.error(`error: \`${what}\` failed for ${subject}`);
    process.exit(result.status);
  }
}

/** Reports a wrapper-level failure under the entry script's name and exits. */
function fail(message) {
  console.error(`error: ${ENTRY_NAME}: ${message}`);
  process.exit(1);
}
