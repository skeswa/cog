#!/usr/bin/env node

// Runs the Swift test suite for one or more isolation-matrix legs.
//
// Why this exists rather than a bare `swift test`:
//
//   1. SwiftPM exits 0 when `--filter` selects nothing. It prints
//      `warning: No matching test cases were run` and then reports a passing
//      run of zero tests. A task whose `_Verify:_` line is a filtered run
//      could therefore claim a green it never proved. Every filtered run
//      through this wrapper is guarded twice: `swift test list` is consulted
//      before the run, and the run's own xUnit report is counted after it.
//   2. The four legs of the isolation matrix differ only by environment
//      (`COG_TEST_ISOLATION`, `COG_TEST_NNBD`), which SwiftPM does not model
//      as a build input. Each leg — and each build configuration — therefore
//      gets its own scratch path so the legs cannot thrash or reuse each
//      other's artifacts.
//
// Usage: `swift-test.mjs <default|release|matrix> [swift test arguments...]`
//
// Everything after the mode is passed through to `swift test` untouched, so
// `--filter`, `--parallel`, `--verbose` and friends all work. The exit status
// is the first failing leg's; a matrix run stops at that leg.

import { spawnSync } from "node:child_process";
import { mkdtempSync, readdirSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

/**
 * The four legs of the isolation matrix.
 *
 * `M0-04` teaches `Package.swift` to read these variables. Until it lands the
 * manifest ignores them and all four legs build identically, which is fine:
 * setting them here now keeps `M0-04` a manifest-only change.
 *
 * The first entry is the default leg. It must stay in sync with the constants
 * the manifest currently hard-codes for its test targets.
 */
const LEGS = [
  { name: "mainactor-nnbd-on", isolation: "mainactor", nnbd: "1" },
  { name: "mainactor-nnbd-off", isolation: "mainactor", nnbd: "0" },
  { name: "nonisolated-nnbd-on", isolation: "nonisolated", nnbd: "1" },
  { name: "nonisolated-nnbd-off", isolation: "nonisolated", nnbd: "0" },
];

/** The leg every unqualified command runs. */
const DEFAULT_LEG = LEGS[0];

/** What each wrapper mode selects: a build configuration and a set of legs. */
const MODES = new Map([
  ["default", { configuration: "debug", legs: [DEFAULT_LEG] }],
  ["release", { configuration: "release", legs: [DEFAULT_LEG] }],
  ["matrix", { configuration: "debug", legs: LEGS }],
]);

/** The repository root, resolved from this file so cwd never matters. */
const REPO_ROOT = fileURLToPath(new URL("..", import.meta.url));

main(process.argv.slice(2));

function main(argv) {
  const [mode, ...passthrough] = argv;
  const selection = MODES.get(mode);
  if (selection === undefined) {
    fail(
      `unknown mode ${JSON.stringify(mode ?? "")}; ` +
        `expected one of ${[...MODES.keys()].join(", ")}`,
    );
  }

  const filters = extractFilters(passthrough);
  for (const leg of selection.legs) {
    runLeg(leg, selection.configuration, filters, passthrough);
  }
}

/**
 * Runs one leg: enumerate and guard when filtered, test, then count.
 *
 * Exits the process on the first failure rather than returning, so a failing
 * leg always fails the whole command.
 */
function runLeg(leg, configuration, filters, passthrough) {
  const scratchPath = `.build/${leg.name}-${configuration}`;
  const environment = legEnvironment(leg);
  const common = ["-c", configuration, "--scratch-path", scratchPath];

  // Escape hatch for `M0-04`: SwiftPM does not treat `Context.environment`
  // reads as manifest cache inputs, so if the legs ever stop re-evaluating
  // the manifest, export `COG_TEST_MANIFEST_CACHE=none` (or `local`) rather
  // than editing this wrapper or the mise tasks.
  const manifestCache = process.env.COG_TEST_MANIFEST_CACHE;
  if (manifestCache !== undefined && manifestCache !== "") {
    common.push("--manifest-cache", manifestCache);
  }

  console.log(
    `\n==> swift test [leg ${leg.name}] [${configuration}] ` +
      `COG_TEST_ISOLATION=${leg.isolation} COG_TEST_NNBD=${leg.nnbd}`,
  );

  if (filters.length > 0) {
    const listed = spawnSync("swift", ["test", "list", ...common], {
      cwd: REPO_ROOT,
      encoding: "utf8",
      env: environment,
      stdio: ["inherit", "pipe", "inherit"],
    });
    exitOnFailure(listed, leg, "swift test list");
    assertFiltersSelectTests(filters, parseSpecifiers(listed.stdout), leg);
  }

  // Counting the run itself is the authoritative guard; the pre-run check
  // above only models SwiftPM's matching. Skipped when the caller wants the
  // xUnit report somewhere of their own, since there is only one such flag.
  let reportDirectory;
  let reportArguments = [];
  if (filters.length > 0 && !passthrough.some(isXUnitArgument)) {
    reportDirectory = mkdtempSync(join(tmpdir(), "cog-swift-test-"));
    reportArguments = ["--xunit-output", join(reportDirectory, "results.xml")];
    // `process.exit` skips `finally`, and every failure path here exits, so
    // the cleanup hangs off the exit event instead.
    const directory = reportDirectory;
    process.on("exit", () => rmSync(directory, { force: true, recursive: true }));
  }

  const tested = spawnSync("swift", ["test", ...common, ...reportArguments, ...passthrough], {
    cwd: REPO_ROOT,
    env: environment,
    stdio: "inherit",
  });
  exitOnFailure(tested, leg, "swift test");
  if (reportDirectory !== undefined) {
    assertRunSelectedTests(filters, reportDirectory, leg);
  }
}

/** The environment one leg builds and runs under. */
function legEnvironment(leg) {
  return {
    ...process.env,
    COG_TEST_ISOLATION: leg.isolation,
    COG_TEST_NNBD: leg.nnbd,
  };
}

/** Collects every `--filter <expr>` and `--filter=<expr>` value, in order. */
function extractFilters(args) {
  const filters = [];
  for (let index = 0; index < args.length; index += 1) {
    const argument = args[index];
    if (argument === "--filter") {
      const value = args[index + 1];
      if (value === undefined) {
        fail("`--filter` was passed without an expression");
      }
      filters.push(value);
      index += 1;
    } else if (argument.startsWith("--filter=")) {
      filters.push(argument.slice("--filter=".length));
    }
  }
  return filters;
}

/** Whether an argument is the caller's own xUnit report destination. */
function isXUnitArgument(argument) {
  return argument === "--xunit-output" || argument.startsWith("--xunit-output=");
}

/**
 * Keeps only the test specifiers from `swift test list` stdout.
 *
 * The build log goes to stderr, but SwiftPM is free to add progress chatter,
 * so only lines shaped like a specifier (`Target.<something>`) are kept.
 */
function parseSpecifiers(stdout) {
  return stdout
    .split("\n")
    .map((line) => line.trim())
    .filter((line) => /^\S+\.\S/.test(line));
}

/**
 * Fails before the run when a filter expression selects nothing.
 *
 * Each top-level alternative of a multi-branch expression is checked too. The
 * ledger's filters are unions of scenario IDs (`'HIST-01|HIST-02'`), so a
 * branch that matches nothing is a coverage claim with no test behind it even
 * when its siblings match. Only this pre-run check can see that; the xUnit
 * count afterwards sees a union that did select something.
 */
function assertFiltersSelectTests(filters, specifiers, leg) {
  const problems = [];
  for (const filter of filters) {
    if (selectionCount(filter, specifiers) === 0) {
      problems.push(`filter selected no tests: ${filter}`);
      continue;
    }
    const alternatives = topLevelAlternatives(filter);
    if (alternatives.length < 2) continue;
    for (const alternative of alternatives) {
      if (selectionCount(alternative, specifiers) === 0) {
        problems.push(
          `filter selected no tests for the alternative ${alternative} ` + `of ${filter}`,
        );
      }
    }
  }
  if (problems.length === 0) return;

  for (const problem of problems) {
    console.error(`error: ${problem}`);
  }
  fail(
    `leg ${leg.name} lists ${specifiers.length} test(s), and SwiftPM exits 0 ` +
      `on an empty selection, so the run above was refused. Run ` +
      `\`swift test list\` to see the available tests.`,
  );
}

/**
 * Fails after the run when the filtered run executed nothing at all.
 *
 * This is the authoritative guard. `selectionCount` only models SwiftPM's
 * matching against the specifiers `swift test list` prints, but Swift Testing
 * matches against a longer identifier — the specifier followed by
 * `/<file>:<line>:<column>` — so an end-anchored expression can pass the
 * pre-run check and still select nothing. The xUnit report cannot be wrong
 * about what ran.
 */
function assertRunSelectedTests(filters, reportDirectory, leg) {
  let reports = 0;
  let executed = 0;
  for (const entry of readdirSync(reportDirectory)) {
    if (!entry.endsWith(".xml")) continue;
    reports += 1;
    const report = readFileSync(join(reportDirectory, entry), "utf8");
    for (const suite of report.matchAll(/<testsuite\b[^>]*\btests="(\d+)"/g)) {
      executed += Number(suite[1]);
    }
  }
  // No report at all means the toolchain declined to write one. Stay quiet
  // rather than failing a run this wrapper cannot see into.
  if (reports === 0 || executed > 0) return;

  for (const filter of filters) {
    console.error(`error: filter selected no tests: ${filter}`);
  }
  fail(
    `leg ${leg.name} ran zero tests under the expression(s) above, and ` +
      `SwiftPM reported that empty run as a success.`,
  );
}

/** How many known specifiers `pattern` selects, using `swift test` semantics. */
function selectionCount(pattern, specifiers) {
  let regex;
  try {
    // Unanchored and case-sensitive, matched against the same specifier
    // strings `swift test list` prints — verified against `swift test
    // --filter` on this toolchain.
    regex = new RegExp(pattern);
  } catch (error) {
    fail(`\`--filter ${pattern}\` is not a valid expression: ${error.message}`);
  }
  return specifiers.filter((specifier) => regex.test(specifier)).length;
}

/**
 * Splits a pattern on its top-level `|`, ignoring escapes, character classes,
 * and grouped alternations. Empty branches are dropped: an empty pattern
 * matches everything and would make the guard vacuous.
 */
function topLevelAlternatives(pattern) {
  const branches = [];
  let branch = "";
  let depth = 0;
  let inCharacterClass = false;

  for (let index = 0; index < pattern.length; index += 1) {
    const character = pattern[index];
    if (character === "\\") {
      branch += character + (pattern[index + 1] ?? "");
      index += 1;
    } else if (inCharacterClass) {
      if (character === "]") inCharacterClass = false;
      branch += character;
    } else if (character === "[") {
      inCharacterClass = true;
      branch += character;
    } else if (character === "(") {
      depth += 1;
      branch += character;
    } else if (character === ")") {
      depth -= 1;
      branch += character;
    } else if (character === "|" && depth === 0) {
      branches.push(branch);
      branch = "";
    } else {
      branch += character;
    }
  }
  branches.push(branch);

  return branches.filter((candidate) => candidate.trim() !== "");
}

/** Propagates a child process's failure, including death by signal. */
function exitOnFailure(result, leg, what) {
  if (result.error !== undefined) {
    fail(`could not run \`${what}\` for leg ${leg.name}: ${result.error.message}`);
  }
  if (result.signal !== null && result.signal !== undefined) {
    fail(`\`${what}\` for leg ${leg.name} was killed by ${result.signal}`);
  }
  if (result.status !== 0) {
    console.error(`error: \`${what}\` failed for leg ${leg.name}`);
    process.exit(result.status);
  }
}

/** Reports a wrapper-level failure and exits non-zero. */
function fail(message) {
  console.error(`error: swift-test: ${message}`);
  process.exit(1);
}
