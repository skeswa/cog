#!/usr/bin/env node
// Fixture runner for tools/check-task-ledger.mjs.
//
//     node tools/test-task-ledger.mjs
//
// Each case runs the checker as a subprocess against one ledger and asserts
// the exit code, the exact set of `error[<check>]` names in its output, and
// that the diagnostics name the offending IDs. Exits non-zero on any mismatch.
//
// Every fixture ledger is self-contained: the checker pairs `<name>.md` with
// the `<name>.scenarios.md` and `<name>.plan.md` beside it, so a fixture's
// scenario census and milestone map are its own and never the repository's.

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
  {
    name: "scenario no task owns",
    ledger: resolve(FIXTURES, "unowned-scenario.md"),
    checks: ["unowned-scenario"],
    mentions: ["DECL-03", "unowned-scenario.scenarios.md:7"],
  },
  {
    name: "scenario greened by two tasks",
    ledger: resolve(FIXTURES, "duplicate-scenario-owner.md"),
    checks: ["duplicate-scenario-owner"],
    mentions: ["DECL-02", "M1-02", "M1-03"],
  },
  {
    name: "green naming a scenario that does not exist",
    ledger: resolve(FIXTURES, "unknown-scenario.md"),
    checks: ["unknown-scenario"],
    mentions: ["M1-03", "DECL-09"],
  },
  {
    name: "infrastructure task that owns a scenario",
    ledger: resolve(FIXTURES, "misplaced-greens.md"),
    checks: ["misplaced-greens"],
    mentions: ["M1-03", "Infrastructure", "DECL-02"],
  },
  {
    name: "behavior no milestone gate covers",
    ledger: resolve(FIXTURES, "unreachable-behavior.md"),
    checks: ["unreachable-behavior"],
    mentions: ["M1-04", "M1-05"],
  },
  {
    name: "allowed non-blocking task passes",
    ledger: resolve(FIXTURES, "non-blocking-allowed.md"),
    checks: [],
  },
  {
    name: "non-blocking line that states no policy",
    ledger: resolve(FIXTURES, "non-blocking-policy.md"),
    checks: ["non-blocking-policy"],
    mentions: ["M1-04", "deferred for now"],
  },
  {
    name: "non-blocking task the gate already covers",
    ledger: resolve(FIXTURES, "unnecessary-non-blocking.md"),
    checks: ["unnecessary-non-blocking"],
    mentions: ["M1-04", "M1-05"],
  },
  {
    name: "milestone with behavior and no gate",
    ledger: resolve(FIXTURES, "missing-milestone-gate.md"),
    checks: ["milestone-gate"],
    mentions: ["M1", "no _(Gate)_ task"],
  },
  {
    name: "milestone whose gates have no closing path",
    ledger: resolve(FIXTURES, "ambiguous-milestone-gate.md"),
    checks: ["milestone-gate"],
    mentions: ["M1-03, M1-04", "no single terminal gate"],
  },
  {
    name: "milestone the plan's map never rows",
    ledger: resolve(FIXTURES, "plan-missing-row.md"),
    checks: ["plan-milestone-row"],
    mentions: ["no row for M1", "plan-missing-row.plan.md:5"],
  },
  {
    name: "map row linking to a section the ledger has not got",
    ledger: resolve(FIXTURES, "plan-wrong-link.md"),
    checks: ["plan-task-link"],
    mentions: ["`#m1-task`", "an anchor the ledger does not define", "`#m1-tasks`"],
  },
  {
    name: "map row naming a task the ledger never defines",
    ledger: resolve(FIXTURES, "plan-unknown-id.md"),
    checks: ["plan-task-reference"],
    mentions: ["M1 row names M1-09", "not an executable task"],
  },
  {
    name: "map row naming another milestone's task",
    ledger: resolve(FIXTURES, "plan-cross-milestone-id.md"),
    checks: ["plan-task-reference"],
    mentions: ["M1 row names M0-01", "belongs to M0"],
  },
  {
    name: "non-blocking task the plan's row never names",
    ledger: resolve(FIXTURES, "plan-missing-non-blocking.md"),
    checks: ["plan-non-blocking-row"],
    mentions: ["M1-04", "the M1 row does not name it"],
  },
  {
    name: "every proof mode proven the right way passes",
    ledger: resolve(FIXTURES, "proof-modes-valid.md"),
    checks: [],
  },
  {
    name: "compile-fail scenario its verification never compiles",
    ledger: resolve(FIXTURES, "mode-mismatch.md"),
    checks: ["proof-mode-command"],
    mentions: ["M1-02", "DECL-06", "compile-fail", "mise run test:compilefail"],
  },
  {
    name: "gate owning a scenario only a behavior task may own",
    ledger: resolve(FIXTURES, "gate-ownership.md"),
    checks: ["gate-proof-mode"],
    mentions: ["M1-03", "DECL-02", "`unit`", "belongs to a behavior task"],
  },
  {
    name: "exit test filtered in debug but never in release",
    ledger: resolve(FIXTURES, "missing-release-filter.md"),
    checks: ["exit-test-release"],
    mentions: ["M1-03", "TURN-07", "`mise run test:release --filter`"],
  },
  {
    name: "behavior filter that selects more than the task greens",
    ledger: resolve(FIXTURES, "over-broad-filter.md"),
    checks: ["filter-expansion"],
    mentions: ["M1-02", "DECL-0[1-3]", "also selects DECL-03"],
  },
  {
    name: "two release sequences that can interleave",
    ledger: resolve(FIXTURES, "forked-release-chain.md"),
    checks: ["release-chain"],
    mentions: ["M1-03", "M2-03", "not dependency-ordered"],
  },
  {
    name: "publication no gate stands behind",
    ledger: resolve(FIXTURES, "gateless-release.md"),
    checks: ["release-after-gate"],
    mentions: ["M1-03", "transitively depends on no _(Gate)_ task"],
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
