#!/usr/bin/env node
// Validates the Swift implementation task ledger.
//
//     node tools/check-task-ledger.mjs [path/to/tasks.md] [--scenarios path]
//         [--plan path] [--json]
//
// Defaults to docs/swift/impl/tasks.md. The scenario census comes from
// docs/swift/impl/scenarios.md and the milestone map from
// docs/swift/impl/plan.md, unless `--scenarios` or `--plan` names another
// file, or the ledger has a paired `<name>.scenarios.md` or `<name>.plan.md`
// beside it — which is how fixtures stay self-contained. Exits 0 with a
// one-line summary when every check passes, and non-zero with one greppable
// `error[<check>]` line per failure otherwise.
//
// Checks in the first slice (M0-09aa):
//
//   duplicate-task-id         executable task IDs are unique
//   parent-child-coexistence  executable task IDs are prefix-free
//   unknown-dependency        every `_Depends:_` ID exists
//   redundant-dependency      dependency lists are transitively minimal
//   dependency-cycle          the task graph is acyclic
//
// Added by this slice (M0-09ab):
//
//   misplaced-greens          only behavior tasks and gates own scenarios
//   unknown-scenario          every green names a scenario the tree defines
//   duplicate-scenario-owner  no scenario is greened twice
//   unowned-scenario          every scenario in the tree is greened once
//   milestone-gate            each milestone closes through one terminal gate
//   unreachable-behavior      that gate transitively depends on every behavior
//   non-blocking-policy       `_Non-blocking:_` states an availability policy
//   unnecessary-non-blocking  only unreachable tasks carry that exception
//
// Added by this slice (M0-09ac), over the plan's milestone map:
//
//   plan-milestone-row        exactly one map row per ledger milestone
//   plan-task-link            each row links to that milestone's task section
//   plan-task-reference       rows name existing tasks of their own milestone
//   plan-non-blocking-row     every `_Non-blocking:_` task is named in its row
//
// Added by this slice (M0-11), over each scenario's `(Proof: …)` mode:
//
//   gate-proof-mode           only suite/release-configuration greens on gates
//   filter-expansion          behavior filters expand to exactly their greens
//   exit-test-release         exit-test greens run in debug and in release
//   proof-mode-command        every other mode names the run that proves it
//
// Added by this slice (M0-12), over the shape of the dependency graph:
//
//   release-chain             _Release_ tasks form one total dependency order
//   release-after-gate        every _Release_ task sits downstream of a _Gate_
//   arena-integration-coverage
//                             M6's arena filters re-prove every filterable
//                             M1–M6 scenario, bar the ones the milestone's
//                             `_Arena-coverage exceptions:_` note names
//
// Parse-level problems (`malformed-task-entry`, `malformed-task-id`,
// `unknown-task-type`, `orphan-task`, `duplicate-field`,
// `malformed-dependency`, `malformed-green`, `duplicate-scenario-id`,
// `unknown-proof-mode`, `empty-scenario-census`, `missing-plan-table`,
// `malformed-plan-row`) are reported the same way.

import { existsSync, readFileSync } from "node:fs";
import { relative, resolve } from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

import { runChecks } from "./lib/task-ledger/checks.mjs";
import { parseLedger } from "./lib/task-ledger/parse.mjs";
import { parsePlan } from "./lib/task-ledger/plan.mjs";
import { parseScenarios } from "./lib/task-ledger/scenarios.mjs";

const REPO_ROOT = resolve(fileURLToPath(new URL("..", import.meta.url)));
const DEFAULT_LEDGER = resolve(REPO_ROOT, "docs/swift/impl/tasks.md");
const DEFAULT_SCENARIOS = resolve(REPO_ROOT, "docs/swift/impl/scenarios.md");
const DEFAULT_PLAN = resolve(REPO_ROOT, "docs/swift/impl/plan.md");

const USAGE =
  "usage: node tools/check-task-ledger.mjs [path/to/tasks.md] " +
  "[--scenarios path/to/scenarios.md] [--plan path/to/plan.md] [--json]\n";

/** @param {string[]} argv */
function parseArgs(argv) {
  let json = false;
  /** @type {string | null} */
  let path = null;
  /** @type {string | null} */
  let scenarios = null;
  /** @type {string | null} */
  let plan = null;

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--json") {
      json = true;
      continue;
    }
    if (arg === "--help" || arg === "-h") {
      process.stdout.write(USAGE);
      process.exit(0);
    }
    if (arg === "--scenarios" || arg.startsWith("--scenarios=")) {
      const value = arg === "--scenarios" ? argv[(index += 1)] : arg.slice("--scenarios=".length);
      if (value === undefined || value.length === 0) {
        process.stderr.write("check-task-ledger: --scenarios needs a path\n");
        process.exit(2);
      }
      scenarios = resolve(value);
      continue;
    }
    if (arg === "--plan" || arg.startsWith("--plan=")) {
      const value = arg === "--plan" ? argv[(index += 1)] : arg.slice("--plan=".length);
      if (value === undefined || value.length === 0) {
        process.stderr.write("check-task-ledger: --plan needs a path\n");
        process.exit(2);
      }
      plan = resolve(value);
      continue;
    }
    if (arg.startsWith("-")) {
      process.stderr.write(`check-task-ledger: unknown option ${arg}\n`);
      process.exit(2);
    }
    if (path !== null) {
      process.stderr.write("check-task-ledger: expected at most one path\n");
      process.exit(2);
    }
    path = arg;
  }

  const ledgerPath = path === null ? DEFAULT_LEDGER : resolve(path);
  return {
    path: ledgerPath,
    scenarios: scenarios ?? paired(ledgerPath, ".scenarios.md", DEFAULT_SCENARIOS),
    plan: plan ?? paired(ledgerPath, ".plan.md", DEFAULT_PLAN),
    json,
  };
}

/**
 * A ledger's companion document: the `<name>.scenarios.md` or `<name>.plan.md`
 * beside it when one exists, and the repository's own otherwise.
 *
 * @param {string} ledgerPath
 * @param {string} suffix
 * @param {string} fallback
 */
function paired(ledgerPath, suffix, fallback) {
  const candidate = ledgerPath.replace(/\.md$/, suffix);
  return candidate !== ledgerPath && existsSync(candidate) ? candidate : fallback;
}

/** Repo-relative path when the file is inside the repo, absolute otherwise. */
function displayPath(path) {
  const rel = relative(REPO_ROOT, path);
  if (rel.length === 0 || rel.startsWith("..")) return path;
  return rel;
}

/** @param {object} item */
function formatDiagnostic(item) {
  return `${displayPath(item.path)}:${item.line}: error[${item.check}]: ${item.message}`;
}

/** @param {string} path */
function read(path) {
  try {
    return readFileSync(path, "utf8");
  } catch (error) {
    process.stderr.write(`check-task-ledger: cannot read ${path}: ${error.message}\n`);
    process.exit(2);
  }
}

function main() {
  const { path, scenarios: scenariosPath, plan: planPath, json } = parseArgs(process.argv.slice(2));

  const parsed = parseLedger(read(path), path);
  const scenarios = parseScenarios(read(scenariosPath), scenariosPath);
  const plan = parsePlan(read(planPath), planPath);
  const { diagnostics: checkDiagnostics, checkNames } = runChecks(path, parsed.tasks, scenarios, {
    plan,
    ledger: {
      milestones: parsed.milestones,
      milestoneAnchors: parsed.milestoneAnchors,
      anchors: parsed.anchors,
      notes: parsed.notes,
    },
  });
  const diagnostics = [
    ...parsed.diagnostics,
    ...scenarios.diagnostics,
    ...plan.diagnostics,
    ...checkDiagnostics,
  ].sort(
    (a, b) => a.path.localeCompare(b.path) || a.line - b.line || a.check.localeCompare(b.check),
  );

  if (json) {
    process.stdout.write(
      `${JSON.stringify(
        {
          path: displayPath(path),
          scenariosPath: displayPath(scenariosPath),
          planPath: displayPath(planPath),
          taskCount: parsed.tasks.length,
          scenarioCount: scenarios.ids.length,
          scenarioModes: Object.fromEntries([...scenarios.modeCounts].sort()),
          planRowCount: plan.rows.length,
          milestones: parsed.milestones,
          checks: checkNames,
          diagnostics: diagnostics.map((item) => ({
            check: item.check,
            path: displayPath(item.path),
            line: item.line,
            taskId: item.taskId,
            message: item.message,
          })),
        },
        null,
        2,
      )}\n`,
    );
    process.exit(diagnostics.length === 0 ? 0 : 1);
  }

  if (diagnostics.length > 0) {
    for (const item of diagnostics) {
      process.stderr.write(`${formatDiagnostic(item)}\n`);
    }
    const failed = [...new Set(diagnostics.map((item) => item.check))].sort();
    process.stderr.write(
      `check-task-ledger: FAILED ${displayPath(path)} — ` +
        `${diagnostics.length} problem(s) in ${failed.length} check(s): ${failed.join(", ")}\n`,
    );
    process.exit(1);
  }

  const edges = parsed.tasks.reduce((total, task) => total + task.depends.length, 0);
  const modes = [...scenarios.modeCounts]
    .sort()
    .map(([mode, count]) => `${count} ${mode}`)
    .join(", ");
  process.stdout.write(
    `check-task-ledger: OK ${displayPath(path)} — ` +
      `${parsed.tasks.length} tasks, ${edges} dependency edges, ` +
      `${parsed.milestones.length} milestone(s) [${parsed.milestones.join(" ")}]; ` +
      `${scenarios.ids.length} scenarios from ${displayPath(scenariosPath)} ` +
      `(${modes}), each owned once; ` +
      `${plan.rows.length} milestone map row(s) from ${displayPath(planPath)}, each mapped once; ` +
      `${checkNames.length} checks passed: ${checkNames.join(", ")}\n`,
  );
}

main();
