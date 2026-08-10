#!/usr/bin/env node
// Validates the Swift implementation task ledger.
//
//     node tools/check-task-ledger.mjs [path/to/tasks.md] [--json]
//
// Defaults to docs/swift/impl/tasks.md. Exits 0 with a one-line summary when
// every check passes, and non-zero with one greppable `error[<check>]` line
// per failure otherwise.
//
// Checks in this slice (M0-09aa):
//
//   duplicate-task-id         executable task IDs are unique
//   parent-child-coexistence  executable task IDs are prefix-free
//   unknown-dependency        every `_Depends:_` ID exists
//   redundant-dependency      dependency lists are transitively minimal
//   dependency-cycle          the task graph is acyclic
//
// Parse-level problems (`malformed-task-entry`, `malformed-task-id`,
// `unknown-task-type`, `orphan-task`, `duplicate-field`,
// `malformed-dependency`, `malformed-green`) are reported the same way.

import { readFileSync } from "node:fs";
import { relative, resolve } from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

import { runChecks } from "./lib/task-ledger/checks.mjs";
import { parseLedger } from "./lib/task-ledger/parse.mjs";

const REPO_ROOT = resolve(fileURLToPath(new URL("..", import.meta.url)));
const DEFAULT_LEDGER = resolve(REPO_ROOT, "docs/swift/impl/tasks.md");

/** @param {string[]} argv */
function parseArgs(argv) {
  let json = false;
  /** @type {string | null} */
  let path = null;
  for (const arg of argv) {
    if (arg === "--json") {
      json = true;
      continue;
    }
    if (arg === "--help" || arg === "-h") {
      process.stdout.write("usage: node tools/check-task-ledger.mjs [path/to/tasks.md] [--json]\n");
      process.exit(0);
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
  return { path: path === null ? DEFAULT_LEDGER : resolve(path), json };
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

function main() {
  const { path, json } = parseArgs(process.argv.slice(2));

  let source;
  try {
    source = readFileSync(path, "utf8");
  } catch (error) {
    process.stderr.write(`check-task-ledger: cannot read ${path}: ${error.message}\n`);
    process.exit(2);
  }

  const parsed = parseLedger(source, path);
  const { diagnostics: checkDiagnostics, checkNames } = runChecks(path, parsed.tasks);
  const diagnostics = [...parsed.diagnostics, ...checkDiagnostics].sort(
    (a, b) => a.line - b.line || a.check.localeCompare(b.check),
  );

  if (json) {
    process.stdout.write(
      `${JSON.stringify(
        {
          path: displayPath(path),
          taskCount: parsed.tasks.length,
          milestones: parsed.milestones,
          checks: checkNames,
          diagnostics: diagnostics.map((item) => ({
            check: item.check,
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
  process.stdout.write(
    `check-task-ledger: OK ${displayPath(path)} — ` +
      `${parsed.tasks.length} tasks, ${edges} dependency edges, ` +
      `${parsed.milestones.length} milestone(s) [${parsed.milestones.join(" ")}]; ` +
      `${checkNames.length} checks passed: ${checkNames.join(", ")}\n`,
  );
}

main();
