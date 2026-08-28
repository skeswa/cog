#!/usr/bin/env node

// Crosses the scenario ledger against the test sources, both directions.
//
// A scenario ID reaches its proof through several spellings — a ledger
// bullet, a test display name or comment, a compile-fail directive — and
// until this checker only the compile-fail spelling was verified. Two claims
// are proven here, without building anything:
//
//   1. Every live ledger ID whose proof mode lives in this repository's test
//      sources is actually mentioned there: unit and exit-test proofs in
//      `swift/Tests` (or `swift/Lint/Tests` for the LINT family), simulator
//      proofs in `CogBoundaryTests`, and compile-fail and release-absence
//      proofs as `// scenario:` directives in `swift/CompileFail`. An ID that
//      is "proven elsewhere" says so with a proof annotation; an ID with no
//      annotation and no mention is a promise nothing keeps.
//   2. Every ID-shaped token in a `@Test` display name is a live ledger ID,
//      so a retired ID cannot be reused and a typo cannot green a claim that
//      was never made. Prose mentions of retired IDs in comments remain the
//      welcome breadcrumbs they are — only display names are held to this.
//
// Modes whose proof lives outside these sources — `suite`, `floor runtime`,
// `benchmark` (the PERF family's default), and `release configuration`
// (proven by the release test leg) — are skipped, and the skip counts are
// printed so coverage gaps stay visible rather than silently passing.

import { readdirSync, readFileSync } from "node:fs";
import { join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { readScenarioLedger } from "./lib/scenario-ledger.mjs";

/** The repository root, resolved from this file so cwd never matters. */
const REPO_ROOT = fileURLToPath(new URL("..", import.meta.url));

/** The ledger this checker keeps honest. */
const SCENARIOS = resolve(REPO_ROOT, "docs/swift/impl/scenarios.md");

/** Proof modes whose evidence lives outside the scanned test sources. */
const EXTERNAL_MODES = new Set(["suite", "floor runtime", "benchmark", "release configuration"]);

/** Matches one ID-shaped token, the same shape the ledger's bullets use. */
const ID_TOKEN = /[A-Z][A-Z0-9]*-\d+[a-z]?/g;

main();

/** Runs both cross-checks and reports what was skipped and why. */
function main() {
  const ledger = readScenarioLedger(SCENARIOS);
  if (ledger === null) {
    fail(`could not parse any scenario bullets out of ${relative(REPO_ROOT, SCENARIOS)}`);
  }

  const testSources = readSources([
    join(REPO_ROOT, "swift", "Tests"),
    join(REPO_ROOT, "swift", "Lint", "Tests"),
  ]);
  const boundarySources = testSources.filter(({ path }) =>
    path.includes(join("swift", "Tests", "CogBoundaryTests")),
  );
  const compileFailSources = readSources([join(REPO_ROOT, "swift", "CompileFail")]);

  const problems = [];
  const skipped = new Map();
  for (const [id, entry] of ledger) {
    if (entry.pending) {
      count(skipped, "pending");
      continue;
    }
    const external = [...entry.proofs].find((mode) => EXTERNAL_MODES.has(mode));
    if (external !== undefined) {
      count(skipped, external);
      continue;
    }
    // The ledger's rules make `benchmark` the PERF family's default, so an
    // unannotated PERF bullet is threshold-proven rather than unproven.
    if (entry.family === "PERF" && entry.proofs.size === 0) {
      count(skipped, "benchmark");
      continue;
    }
    if (entry.proofs.has("compile-fail") || entry.proofs.has("release absence")) {
      const directive = new RegExp(`//\\s*scenario:\\s*${id}\\b`);
      if (!compileFailSources.some(({ text }) => directive.test(text))) {
        problems.push(
          `${id} promises a compile-fail proof, but swift/CompileFail has no ` +
            `\`// scenario: ${id}\` directive`,
        );
      }
      continue;
    }
    const homes = entry.proofs.has("simulator") ? boundarySources : testSources;
    const home = entry.proofs.has("simulator") ? "CogBoundaryTests" : "the test sources";
    if (!homes.some(({ text }) => text.includes(id))) {
      problems.push(`${id} is a live ledger promise, but ${home} never mention it`);
    }
  }

  const liveNamedIDs = verifyTestNames(ledger, testSources, problems);

  if (problems.length > 0) {
    fail(problems.join("\nerror: check-scenario-ledger: "));
  }
  const skips = [...skipped].map(([mode, total]) => `${mode} ${total}`).join(", ");
  console.log(
    `check-scenario-ledger: ${ledger.size} ledger IDs crossed against ` +
      `${testSources.length} test files (${liveNamedIDs} IDs in test names; skipped: ${skips})`,
  );
}

/** Every ID-shaped token in a `@Test` display name must be a live ledger ID. */
function verifyTestNames(ledger, sources, problems) {
  const named = new Set();
  for (const { path, text } of sources) {
    // Any backticked function name, not just `@Test func`: a trait such as
    // `@Test(.timeLimit(…))` puts arguments between the attribute and `func`,
    // and a raw-identifier name outside a test would still be wrong to stamp
    // with an ID the ledger does not carry.
    for (const match of text.matchAll(/\bfunc\s+`([^`]+)`/g)) {
      for (const token of match[1].matchAll(ID_TOKEN)) {
        if (ledger.has(token[0])) {
          named.add(token[0]);
          continue;
        }
        problems.push(
          `${relative(REPO_ROOT, path)} names ${token[0]} in a @Test display name, but the ` +
            "ledger has no such live ID — retired IDs are never reused",
        );
      }
    }
  }
  return named.size;
}

/** Reads every Swift file under the given roots, tolerating a missing root. */
function readSources(roots) {
  const sources = [];
  for (const root of roots) {
    let entries;
    try {
      entries = readdirSync(root, { recursive: true, withFileTypes: false });
    } catch {
      continue;
    }
    for (const entry of entries) {
      if (!entry.endsWith(".swift")) continue;
      const path = join(root, entry);
      sources.push({ path, text: readFileSync(path, "utf8") });
    }
  }
  return sources;
}

/** Increments one skip-mode tally. */
function count(tallies, mode) {
  tallies.set(mode, (tallies.get(mode) ?? 0) + 1);
}

/** Reports every problem under this checker's name and exits nonzero. */
function fail(message) {
  console.error(`error: check-scenario-ledger: ${message}`);
  process.exit(1);
}
