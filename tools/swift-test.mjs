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
// Usage:
// `swift-test.mjs <default|release|matrix|arena-configurations> [swift test arguments...]`
//
// Everything after the mode is passed through to `swift test` untouched, so
// `--filter`, `--verbose` and other options all work. The exit status
// is the first failing leg's; a matrix run stops at that leg.

import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import {
  assertFiltersSelectTests,
  assertRunSelectedTests,
  extractFilters,
  extractTraitArguments,
  isXUnitArgument,
  parseSpecifiers,
  traitArgumentsEnable,
} from "./lib/swift-test-guard.mjs";
import { shippingManifestEnvironment } from "./lib/cog-environment.mjs";

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

// Every leg is also a mode of its own, so CI can give each leg its own job —
// its own runner, scratch path, and cache — instead of looping all four inside
// one job. `matrix` stays the local spelling; the per-leg modes exist for
// `swift-ci.yml`. Derived from LEGS, so a new leg needs no edit here and the
// unknown-mode error lists it automatically.
for (const leg of LEGS) {
  MODES.set(leg.name, { configuration: "debug", legs: [leg] });
}

/** The repository root, resolved from this file so cwd never matters. */
const REPO_ROOT = fileURLToPath(new URL("..", import.meta.url));

main(process.argv.slice(2));

function main(argv) {
  const [mode, ...passthrough] = argv;
  if (mode === "arena-configurations") {
    runArenaConfigurations(passthrough);
    return;
  }
  const selection = MODES.get(mode);
  if (selection === undefined) {
    fail(
      `unknown mode ${JSON.stringify(mode ?? "")}; ` +
        `expected one of ${[...MODES.keys()].join(", ")}`,
    );
  }

  const filters = extractFilters(passthrough, fail);
  const traitArguments = extractTraitArguments(passthrough, fail);
  for (const leg of selection.legs) {
    runLeg(leg, selection.configuration, filters, traitArguments, passthrough);
  }
}

/**
 * Runs the shipping specialization and public CompactArena opt-out from an
 * environment with no ambient retired selectors.
 */
function runArenaConfigurations(passthrough) {
  if (extractTraitArguments(passthrough, fail).length > 0) {
    fail("arena-configurations owns its trait arguments; do not pass another trait option");
  }
  if (passthrough.includes("--parallel")) {
    fail("arena-configurations is serialized; remove `--parallel`");
  }

  const serialized = passthrough.includes("--no-parallel")
    ? passthrough
    : ["--no-parallel", ...passthrough];
  const requestedFilters = extractFilters(serialized, fail);
  const behaviorArguments =
    requestedFilters.length > 0 ? serialized : [...serialized, "--filter", "[A-Z]+-[0-9][0-9]"];
  const sentinelArguments = ["--no-parallel", "--filter", "ArenaSpecializationInfrastructure"];
  const shippingEnvironment = shippingManifestEnvironment(process.env);

  console.log("==> shipping default (specialized arena)");
  runOneConfiguration(sentinelArguments, shippingEnvironment);
  runOneConfiguration(behaviorArguments, shippingEnvironment);

  console.log("==> public opt-out (CompactArena trait)");
  const traitArguments = ["--traits", "CompactArena"];
  runOneConfiguration([...traitArguments, ...sentinelArguments], shippingEnvironment);
  runOneConfiguration([...traitArguments, ...behaviorArguments], shippingEnvironment);
}

/** Runs one default-leg configuration with guards derived from its arguments. */
function runOneConfiguration(arguments_, environment) {
  runLeg(
    DEFAULT_LEG,
    "debug",
    extractFilters(arguments_, fail),
    extractTraitArguments(arguments_, fail),
    arguments_,
    environment,
  );
}

/**
 * Runs one leg: enumerate and guard when filtered, test, then count.
 *
 * Exits the process on the first failure rather than returning, so a failing
 * leg always fails the whole command.
 */
function runLeg(
  leg,
  configuration,
  filters,
  traitArguments,
  passthrough,
  baseEnvironment = process.env,
) {
  const environment = legEnvironment(leg, baseEnvironment, traitArguments);
  const scratchPath = `.build/${leg.name}-${configuration}` + scratchVariant(traitArguments);
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
    const listed = spawnSync("swift", ["test", "list", ...common, ...traitArguments], {
      cwd: REPO_ROOT,
      encoding: "utf8",
      env: environment,
      stdio: ["inherit", "pipe", "inherit"],
    });
    exitOnFailure(listed, leg, "swift test list");
    assertFiltersSelectTests(filters, parseSpecifiers(listed.stdout), `leg ${leg.name}`, fail);
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
    assertRunSelectedTests(filters, reportDirectory, `leg ${leg.name}`, fail);
  }
}

/** The environment one leg builds and runs under. */
function legEnvironment(leg, baseEnvironment, traitArguments) {
  const environment = {
    ...baseEnvironment,
    COG_TEST_ISOLATION: leg.isolation,
    COG_TEST_NNBD: leg.nnbd,
  };
  delete environment.COG_EXPECT_COMPACT_ARENA_TRAIT;
  if (traitArgumentsEnable(traitArguments, "CompactArena")) {
    environment.COG_EXPECT_COMPACT_ARENA_TRAIT = "1";
  }
  return environment;
}

/** Keeps package variants from overwriting or invalidating one another's artifacts. */
function scratchVariant(traitArguments) {
  if (traitArguments.length === 0) return "";
  const digest = createHash("sha256")
    .update(JSON.stringify(traitArguments))
    .digest("hex")
    .slice(0, 12);
  return `-package-${digest}`;
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
