#!/usr/bin/env node
// Pinned-environment benchmark gates.
//
//     node tools/bench-baseline.mjs update [name]
//     node tools/bench-baseline.mjs check  [name]
//     node tools/bench-baseline.mjs thresholds-check
//     node tools/bench-baseline.mjs thresholds-sentinel
//
// A benchmark number means nothing without the machine and toolchain that
// produced it. perf §9 says every baseline pins its environment — exact Xcode
// and Swift version, harness version, architecture, allocator backend, and
// where it ran — and this tool is what makes that mechanical instead of
// remembered. `update` records the environment beside the baseline; `check`
// refuses to compare against a baseline the current environment does not
// match, and says exactly which field moved.
//
// ## Why refusing is the point
//
// Upstream's own documentation says malloc metrics are not comparable across
// allocator backends and that the stored baseline representation is not
// stable. A cross-environment comparison therefore does not produce a wrong
// answer that a human might notice — it produces a plausible one. The
// environment gate turns that into a loud failure.
//
// `thresholds-check` is the portable CI half: it validates the complete set of
// committed static references, proves each benchmark is registered, asserts
// the allocation witness, and then applies the source-defined p90 ceilings.
// `thresholds-sentinel` proves the same harness path rejects a regression.
//
// ## The witness
//
// `check` also asserts that `perf-witness-allocating` reports a NON-ZERO
// malloc count. `M5-05bb` found that a run with the malloc interposer disabled
// reports `mallocCountTotal == 0` for a workload that demonstrably allocates,
// which means a suite whose every threshold is zero passes just as happily
// when nothing is being measured at all. Upstream thresholds are upper bounds
// and cannot express a floor, so the floor lives here.
//
// ## Where things live
//
// Baselines and their metadata live under
// `swift/Benchmarks/.benchmarkBaselines/`, which is git-ignored on purpose:
// the format is upstream-unstable, and a baseline is a statement about one
// machine. Numbers that outlive a session belong in docs/swift/impl/benchmarks.md, written by
// hand, with their environment beside them. Portable zero references live in
// `swift/Benchmarks/Thresholds/`; their one-sided tolerances live in benchmark
// source so a code review sees the effective ceilings.

import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const repositoryRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const benchmarkPackage = join(repositoryRoot, "swift", "Benchmarks");
const baselineDirectory = join(benchmarkPackage, ".benchmarkBaselines");
const thresholdDirectory = join(benchmarkPackage, "Thresholds");

/** The benchmark whose whole job is to allocate, so a silent zero cannot hide. */
const WITNESS_BENCHMARK = "perf-witness-allocating";

/** Benchmarks whose committed p90 references form the CI performance gate. */
const THRESHOLDED_BENCHMARKS = [
  "perf-01-steady-turn",
  "perf-06-value-reference",
  "perf-11-pinned-key-slope-1000",
  "perf-13-deep-chain",
  "perf-10-cog-diamond",
  "perf-10-cog-deep",
  "perf-10-cog-broad",
  "perf-10-cog-unstable",
  "perf-10-observation-diamond",
  "perf-10-observation-deep",
  "perf-10-observation-broad",
  "perf-10-observation-unstable",
  "perf-10-state-graph-diamond",
  "perf-10-state-graph-deep",
  "perf-10-state-graph-broad",
  "perf-10-state-graph-unstable",
];

/**
 * Which metrics each gated benchmark commits a reference for.
 *
 * Most of the gate is wall clock. Four are not: PERF-01, PERF-06 and PERF-13
 * promise an allocation-free steady turn, value reference, and settle walk, and
 * PERF-11 promises that a thousand pinned keys cost a turn what one does, which
 * is a claim about ARC rather than about time.
 */
const STATIC_THRESHOLD_METRICS = {
  "perf-01-steady-turn": ["mallocCountTotal", "objectAllocCount"],
  "perf-06-value-reference": ["mallocCountTotal", "objectAllocCount"],
  "perf-11-pinned-key-slope-1000": ["releaseCount", "retainCount"],
  "perf-13-deep-chain": ["mallocCountTotal", "objectAllocCount"],
};

/** One exact regular expression, so CI measures no ungated workload by accident. */
const THRESHOLD_FILTER = `^(${THRESHOLDED_BENCHMARKS.join("|")})$`;

// Baselines cover every benchmark in the package.
//
// `M5-08a` narrowed this to the `perf-` family as a stopgap, because the
// whole-scenario benchmark crashed the harness roughly one run in six.
// `M5-11` found the cause — a call through a null `swift_release_hook` while
// Cog's cancelled grace sleepers completed on another thread — and bounded it
// where it belongs, by taking the counting metrics off a benchmark whose
// measured region is not quiescent. With the cause addressed rather than
// filtered around, narrowing the baseline would only be hiding benchmarks from
// a gate for no reason.

/** Baseline used when the caller names none. */
const DEFAULT_BASELINE = "local";

/**
 * Runs a command in the benchmark package and returns its stdout.
 *
 * @param {string} command Executable to run.
 * @param {string[]} argv Arguments.
 * @param {{ quiet?: boolean }} [options] `quiet` captures stderr instead of
 *   forwarding it, for probes whose failure is expected and handled.
 * @returns {string} Captured stdout.
 */
function run(command, argv, options = {}) {
  return execFileSync(command, argv, {
    cwd: benchmarkPackage,
    encoding: "utf8",
    maxBuffer: 64 * 1024 * 1024,
    stdio: ["ignore", "pipe", options.quiet ? "pipe" : "inherit"],
  });
}

/**
 * Reads tool version output as one flattened line, tolerating absence.
 *
 * Flattened rather than first-line-only because the fields that matter are not
 * always on line one: `xcodebuild -version` puts the build number on line two,
 * and a build number is exactly the kind of difference that moves a number.
 *
 * @param {string} command Executable to run.
 * @param {string[]} argv Arguments.
 * @returns {string} All non-empty lines joined by a space, or `"unknown"`.
 */
function version(command, argv) {
  try {
    const output = execFileSync(command, argv, {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
    });
    const lines = output
      .split("\n")
      .map((line) => line.trim())
      .filter(Boolean);
    return lines.length > 0 ? lines.join(" ") : "unknown";
  } catch {
    return "unknown";
  }
}

/**
 * Reads a pinned dependency version out of the benchmark package's resolve.
 *
 * The resolve is committed precisely so this is a fact rather than a guess.
 *
 * @param {string} identity SwiftPM package identity.
 * @returns {string} The pinned version, or `"unpinned"`.
 */
function pinnedVersion(identity) {
  const resolvedPath = join(benchmarkPackage, "Package.resolved");
  if (!existsSync(resolvedPath)) return "unpinned";
  const resolved = JSON.parse(readFileSync(resolvedPath, "utf8"));
  const pin = (resolved.pins ?? []).find((candidate) => candidate.identity === identity);
  return pin?.state?.version ?? "unpinned";
}

/**
 * Fingerprints the environment a measurement came from.
 *
 * Every field here can change a number without any source change, which is the
 * test for whether a field belongs. Host name is included not because it
 * changes results by itself but because it names the machine a reader would
 * have to go back to.
 *
 * @returns {Record<string, string>} The fingerprint.
 */
function environment() {
  const allocatorDisabled =
    process.env.BENCHMARK_DISABLE_MALLOC_INTERPOSER !== undefined ||
    process.env.BENCHMARK_DISABLE_JEMALLOC !== undefined;
  return {
    architecture: version("uname", ["-m"]),
    host: version("hostname", ["-s"]),
    os: version("sw_vers", ["-productVersion"]),
    xcode: version("xcodebuild", ["-version"]),
    swift: version("swift", ["--version"]),
    harness: pinnedVersion("benchmark"),
    mallocInterposer: pinnedVersion("malloc-interposer"),
    allocatorBackend: allocatorDisabled ? "disabled" : "malloc-interposer",
  };
}

/** @returns {string} Path of the metadata file recorded beside a baseline. */
function metadataPath(name) {
  return join(baselineDirectory, `${name}.environment.json`);
}

/**
 * Fails with a message, without a stack trace nobody reads.
 *
 * @param {string} message What went wrong and what to do about it.
 * @returns {never}
 */
function fail(message) {
  console.error(`bench-baseline: ${message}`);
  process.exit(1);
}

/**
 * Records a baseline and the environment that produced it.
 *
 * @param {string} name Baseline name.
 */
function update(name) {
  console.log(`==> recording baseline '${name}'`);
  run("swift", [
    "package",
    "--allow-writing-to-package-directory",
    "benchmark",
    "baseline",
    "update",
    name,
    "--no-progress",
  ]);

  mkdirSync(baselineDirectory, { recursive: true });
  const recorded = { baseline: name, recorded: new Date().toISOString(), ...environment() };
  writeFileSync(metadataPath(name), `${JSON.stringify(recorded, null, 2)}\n`);

  console.log(`bench-baseline: OK — recorded '${name}' with its environment`);
  for (const [field, value] of Object.entries(recorded)) {
    console.log(`  ${field.padEnd(18)} ${value}`);
  }
}

/**
 * Asserts the allocation witness is still being measured at all.
 *
 * Exports p90 absolute values as JSON rather than scraping the text table, so
 * a formatting change upstream cannot silently turn this check into a no-op.
 */
function assertWitnessMeasured() {
  const output = run("swift", [
    "package",
    "benchmark",
    "--filter",
    WITNESS_BENCHMARK,
    "--format",
    "metricP90AbsoluteThresholds",
    "--path",
    "stdout",
    "--no-progress",
  ]);

  const start = output.indexOf("{");
  if (start < 0) fail(`the witness benchmark '${WITNESS_BENCHMARK}' produced no metrics at all.`);
  const metrics = JSON.parse(output.slice(start));

  if (!(metrics.mallocCountTotal > 0)) {
    fail(
      `the witness benchmark '${WITNESS_BENCHMARK}' reported mallocCountTotal ` +
        `${metrics.mallocCountTotal}, which means malloc counting is not active. ` +
        "Every zero-allocation threshold in this suite would pass trivially. " +
        "Check that BENCHMARK_DISABLE_MALLOC_INTERPOSER and " +
        "BENCHMARK_DISABLE_JEMALLOC are unset, then rebuild from clean — " +
        "toggling the trait over an existing .build does not take.",
    );
  }
  console.log(
    `bench-baseline: witness OK — '${WITNESS_BENCHMARK}' reports ` +
      `${metrics.mallocCountTotal} mallocs, so counting is live`,
  );
}

/**
 * Checks that every promised static reference exists and remains exactly zero.
 *
 * The harness only fails when it finds no files at all; one surviving file can
 * otherwise hide twelve missing gates. Zero is intentional: benchmark source
 * carries each one-sided absolute tolerance, making that tolerance the actual
 * ceiling and preventing a faster result from exiting as an "improvement".
 *
 * @param {string} directory Directory containing static p90 references.
 */
function assertStaticThresholdsComplete(directory) {
  for (const benchmark of THRESHOLDED_BENCHMARKS) {
    const path = join(directory, `CogGraph.${benchmark}.p90.json`);
    if (!existsSync(path)) fail(`missing static threshold file: ${path}`);

    const thresholds = JSON.parse(readFileSync(path, "utf8"));
    const expectedMetrics = STATIC_THRESHOLD_METRICS[benchmark] ?? ["wallClock"];
    const actualMetrics = Object.keys(thresholds).sort();
    if (JSON.stringify(actualMetrics) !== JSON.stringify(expectedMetrics.sort())) {
      fail(
        `static threshold '${benchmark}' has metrics ${actualMetrics.join(", ")}; ` +
          `expected ${expectedMetrics.join(", ")}`,
      );
    }
    for (const [metric, reference] of Object.entries(thresholds)) {
      if (reference !== 0) {
        fail(
          `static threshold '${benchmark}' uses ${metric} reference ${reference}; ` +
            "references must remain zero so source tolerances are one-sided ceilings",
        );
      }
    }
  }
}

/** Fails if a committed threshold no longer names a registered benchmark. */
function assertThresholdedBenchmarksRegistered() {
  const output = run("swift", ["package", "benchmark", "list", "--no-progress"]);
  const registered = new Set(
    output
      .split("\n")
      .map((line) => line.trim())
      .filter(Boolean),
  );
  const missing = THRESHOLDED_BENCHMARKS.filter((benchmark) => !registered.has(benchmark));
  if (missing.length > 0) {
    fail(`static thresholds name unregistered benchmarks: ${missing.join(", ")}`);
  }
  console.log(
    `bench-baseline: registration OK — found all ${THRESHOLDED_BENCHMARKS.length} thresholded benchmarks`,
  );
}

/** Runs the committed exact-allocation and PERF-10 absolute threshold gate. */
function checkStaticThresholds() {
  assertStaticThresholdsComplete(thresholdDirectory);
  assertThresholdedBenchmarksRegistered();
  assertWitnessMeasured();

  console.log("==> checking committed absolute benchmark thresholds");
  run("swift", [
    "package",
    "benchmark",
    "thresholds",
    "check",
    "--filter",
    THRESHOLD_FILTER,
    "--path",
    thresholdDirectory,
    "--no-progress",
  ]);
  console.log(
    `bench-baseline: OK — ${THRESHOLDED_BENCHMARKS.length} benchmarks stayed within their ceilings`,
  );
}

/**
 * Proves the real threshold path rejects a known regression.
 *
 * A temporary negative reference pushes a fast Observation result beyond its
 * positive source tolerance. This exercises the same benchmark, parser, and
 * threshold comparison as CI without changing either source or committed
 * threshold files.
 */
function checkThresholdSentinel() {
  const benchmark = "perf-10-observation-deep";
  const sentinelDirectory = mkdtempSync(join(tmpdir(), "cog-benchmark-thresholds-"));
  const sentinelPath = join(sentinelDirectory, `CogGraph.${benchmark}.p90.json`);
  writeFileSync(sentinelPath, `${JSON.stringify({ wallClock: -1_000_000_000 }, null, 2)}\n`);

  let regression;
  try {
    run(
      "swift",
      [
        "package",
        "benchmark",
        "thresholds",
        "check",
        "--filter",
        `^${benchmark}$`,
        "--path",
        sentinelDirectory,
        "--no-progress",
      ],
      { quiet: true },
    );
  } catch (error) {
    regression = error;
  } finally {
    rmSync(sentinelDirectory, { recursive: true, force: true });
  }

  if (regression === undefined) {
    fail("the sentinel regression passed; the absolute threshold gate is not active");
  }
  const output = `${regression.stdout ?? ""}\n${regression.stderr ?? ""}`;
  const isThresholdRegression = output.includes("WORSE than the defined thresholds");
  // Direct BenchmarkTool execution uses 2. `swift package` may normalize the
  // plugin's nonzero child status to 1, so the harness diagnostic is the
  // authoritative distinction from a build or launch failure.
  if (![1, 2].includes(regression.status) || !isThresholdRegression) {
    fail(
      `the sentinel command failed for the wrong reason (exit ${regression.status ?? "unknown"}):\n` +
        output.trim().slice(-2_000),
    );
  }
  console.log(
    `bench-baseline: OK — sentinel '${benchmark}' was rejected as a threshold regression`,
  );
}

/**
 * Verifies the environment, the witness, and then the baseline itself.
 *
 * @param {string} name Baseline name.
 */
function check(name) {
  const path = metadataPath(name);
  if (!existsSync(path)) {
    fail(
      `no baseline named '${name}'. Record one first:\n` +
        `  mise run bench:baseline:update ${name}`,
    );
  }

  const recorded = JSON.parse(readFileSync(path, "utf8"));
  const current = environment();
  const drifted = Object.entries(current).filter(([field, value]) => recorded[field] !== value);
  if (drifted.length > 0) {
    const detail = drifted
      .map(([field, value]) => `  ${field}: recorded ${recorded[field]} — now ${value}`)
      .join("\n");
    fail(
      `baseline '${name}' was recorded in a different environment, so comparing ` +
        `against it would produce a plausible answer rather than a right one:\n${detail}\n` +
        `Re-record it with: mise run bench:baseline:update ${name}`,
    );
  }
  console.log(`bench-baseline: environment matches the one '${name}' was recorded in`);

  assertWitnessMeasured();

  console.log(`==> checking against baseline '${name}'`);
  run("swift", ["package", "benchmark", "baseline", "check", name, "--no-progress"]);
  console.log(`bench-baseline: OK — no metric drifted past its threshold`);
}

const [subcommand, name = DEFAULT_BASELINE] = process.argv.slice(2);
switch (subcommand) {
  case "update":
    update(name);
    break;
  case "check":
    check(name);
    break;
  case "thresholds-check":
    checkStaticThresholds();
    break;
  case "thresholds-sentinel":
    checkThresholdSentinel();
    break;
  default:
    fail(
      "expected a subcommand.\n" +
        "  node tools/bench-baseline.mjs update [name]\n" +
        "  node tools/bench-baseline.mjs check  [name]\n" +
        "  node tools/bench-baseline.mjs thresholds-check\n" +
        "  node tools/bench-baseline.mjs thresholds-sentinel",
    );
}
