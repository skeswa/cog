#!/usr/bin/env node
// Fixture runner for tools/check-task-ledger.mjs.
//
//     node tools/test-task-ledger.mjs
//
// Each case runs the checker as a subprocess against one ledger and asserts
// the exit code, the exact set of `error[<check>]` names in its output, and
// that the diagnostics name the offending IDs. Exits non-zero on any mismatch.

import { spawnSync } from "node:child_process";
import { relative, resolve } from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

const TOOLS_DIR = resolve(fileURLToPath(new URL(".", import.meta.url)));
const REPO_ROOT = resolve(TOOLS_DIR, "..");
const CHECKER = resolve(TOOLS_DIR, "check-task-ledger.mjs");
const FIXTURES = resolve(TOOLS_DIR, "fixtures/task-ledger");

/**
 * @typedef {object} Case
 * @property {string} name
 * @property {string} ledger absolute path
 * @property {string[]} checks expected `error[<check>]` names, empty when clean
 * @property {string[]} [mentions] substrings every diagnostic set must contain
 */

/** @type {Case[]} */
const CASES = [
  {
    name: "real ledger passes",
    ledger: resolve(REPO_ROOT, "docs/swift/impl/tasks.md"),
    checks: [],
  },
  {
    name: "valid fixture passes",
    ledger: resolve(FIXTURES, "valid.md"),
    checks: [],
  },
  {
    name: "duplicate executable task ID",
    ledger: resolve(FIXTURES, "duplicate-id.md"),
    checks: ["duplicate-task-id"],
    mentions: ["M1-02a"],
  },
  {
    name: "retired split parent beside its descendant",
    ledger: resolve(FIXTURES, "parent-child-coexistence.md"),
    checks: ["parent-child-coexistence"],
    mentions: ["M1-02", "M1-02a"],
  },
  {
    name: "dependency on a task that does not exist",
    ledger: resolve(FIXTURES, "unknown-dependency.md"),
    checks: ["unknown-dependency"],
    mentions: ["M1-09"],
  },
  {
    name: "dependency list that is not transitively minimal",
    ledger: resolve(FIXTURES, "redundant-edge.md"),
    checks: ["redundant-dependency"],
    mentions: ["M1-03", "M1-02 -> M1-01"],
  },
  {
    name: "cyclic task graph",
    ledger: resolve(FIXTURES, "cycle.md"),
    checks: ["dependency-cycle"],
    mentions: ["M1-02 -> M1-03 -> M1-02"],
  },
];

/** @param {string} ledger */
function runChecker(ledger) {
  const result = spawnSync(process.execPath, [CHECKER, ledger], {
    encoding: "utf8",
  });
  if (result.error !== undefined && result.error !== null) throw result.error;
  return {
    status: result.status,
    output: `${result.stdout ?? ""}${result.stderr ?? ""}`,
  };
}

/** @param {string} output */
function reportedChecks(output) {
  return [...new Set([...output.matchAll(/error\[([a-z-]+)\]/g)].map((m) => m[1]))].sort();
}

/** @param {Case} testCase */
function evaluate(testCase) {
  const { status, output } = runChecker(testCase.ledger);
  const expectedChecks = [...testCase.checks].sort();
  const actualChecks = reportedChecks(output);
  /** @type {string[]} */
  const failures = [];

  const expectedStatus = expectedChecks.length === 0 ? 0 : 1;
  if (status !== expectedStatus) {
    failures.push(`expected exit ${expectedStatus}, got ${status}`);
  }
  if (actualChecks.join(",") !== expectedChecks.join(",")) {
    failures.push(
      `expected checks [${expectedChecks.join(", ")}], got [${actualChecks.join(", ")}]`,
    );
  }
  for (const mention of testCase.mentions ?? []) {
    if (!output.includes(mention)) {
      failures.push(`diagnostics never mention \`${mention}\``);
    }
  }
  return { failures, output };
}

function main() {
  let failed = 0;
  for (const testCase of CASES) {
    const ledger = relative(REPO_ROOT, testCase.ledger);
    const { failures, output } = evaluate(testCase);
    if (failures.length === 0) {
      const expectation =
        testCase.checks.length === 0 ? "clean" : `fires ${testCase.checks.join(", ")}`;
      process.stdout.write(`ok   ${testCase.name} (${ledger}) — ${expectation}\n`);
      continue;
    }
    failed += 1;
    process.stdout.write(`FAIL ${testCase.name} (${ledger})\n`);
    for (const failure of failures) process.stdout.write(`       ${failure}\n`);
    for (const line of output.trimEnd().split("\n")) {
      process.stdout.write(`       | ${line}\n`);
    }
  }

  const total = CASES.length;
  if (failed > 0) {
    process.stdout.write(`\ntest-task-ledger: FAILED ${failed}/${total} case(s)\n`);
    process.exit(1);
  }
  process.stdout.write(`\ntest-task-ledger: PASSED ${total}/${total} cases\n`);
}

main();
