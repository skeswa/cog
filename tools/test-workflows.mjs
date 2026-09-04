#!/usr/bin/env node
// Fixture runner for tools/check-workflows.mjs.
//
//     node tools/test-workflows.mjs
//
// Each case runs the checker as a subprocess against one workflow and asserts
// the exit code, the exact set of `error[<check>]` names in its output, and
// that the diagnostics name the offending jobs. Exits non-zero on any
// mismatch.
//
// The self-hosted cases matter more than the rest right now: `swift-ci.yml`
// does not exist yet (`M0-05b` creates it), so no real workflow in this
// repository runs on the Mac mini and these fixtures are the only proof that
// `self-hosted-guard` fires when it should.

import { spawnSync } from "node:child_process";
import { relative, resolve } from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

const TOOLS_DIR = resolve(fileURLToPath(new URL(".", import.meta.url)));
const REPO_ROOT = resolve(TOOLS_DIR, "..");
const CHECKER = resolve(TOOLS_DIR, "check-workflows.mjs");
const FIXTURES = resolve(TOOLS_DIR, "fixtures/workflows");

/**
 * @typedef {object} Case
 * @property {string} name
 * @property {string} workflow absolute path
 * @property {string[]} checks expected `error[<check>]` names, empty when clean
 * @property {string[]} [mentions] substrings every diagnostic set must contain
 * @property {string[]} [absent] substrings no diagnostic may contain
 */

/** @type {Case[]} */
const CASES = [
  {
    name: "the repository's own workflows pass",
    workflow: resolve(REPO_ROOT, ".github/workflows"),
    checks: [],
  },
  {
    name: "valid hardened workflow passes",
    workflow: resolve(FIXTURES, "valid.yml"),
    checks: [],
  },
  {
    name: "CogLint path, runner, permission, and command drift",
    workflow: resolve(FIXTURES, "coglint-contract-drift/swift-ci.yml"),
    checks: ["coglint-artifact-ci-contract", "coglint-ci-contract"],
    mentions: [
      "`pull_request.paths`",
      "`tools/**`",
      "`lint-swift`",
      "must run on exactly `macos-26`",
      "permissions: {contents: read}",
      "mise run lint:swift",
      "`fork-lint-swift`",
      "`macos-26`",
    ],
  },
  {
    name: "CogLint artifact build, provenance, upload, and Intel handoff drift",
    workflow: resolve(FIXTURES, "coglint-artifact-contract-drift/swift-ci.yml"),
    checks: ["coglint-artifact-ci-contract"],
    mentions: [
      "`workflow_dispatch`",
      "`lint-artifact`",
      "must run on exactly `macos-26`",
      "permissions: {contents: read}",
      "ref: ${{ github.sha }}",
      "mise run test:lint-artifact",
      "PR/source tree, toolchain, architectures, and checksum",
      "build handoff, checksum, and JSON provenance",
      "`lint-artifact-x86_64`",
      "`macos-15-intel`",
      "depend directly on `lint-artifact`",
      "pinned Intel Xcode version and build",
      "download the version/PR-head-qualified build handoff",
      "verify its Intel host",
      "probe the downloaded archive",
      "`Release candidate`",
    ],
  },
  {
    name: "valid protected sibling publication passes",
    workflow: resolve(FIXTURES, "coglint-publication-valid/publish.yml"),
    checks: [],
  },
  {
    name: "sibling preparation that repeats Cog's toolchain pins",
    workflow: resolve(FIXTURES, "coglint-publication-pinned/publish.yml"),
    checks: ["coglint-publication-contract"],
    mentions: ["identity only", "toolchain policy"],
  },
  {
    name: "sibling preparation, environment, immutable push, and consumer drift",
    workflow: resolve(FIXTURES, "coglint-publication-drift/publish.yml"),
    checks: ["coglint-publication-contract"],
    mentions: [
      "`cog_version`",
      "preparation",
      "include-hidden-files",
      "protected sibling publication",
      "exact-tag",
    ],
  },
  {
    name: "Conventional Commit range and command drift",
    workflow: resolve(FIXTURES, "conventional-commits-drift/conventional-commits.yml"),
    checks: ["conventional-commits-contract"],
    mentions: ["no path filters", "authoritative PR head", "mise run changes:check"],
  },
  {
    name: "Release Please pin, recovery, environment, provenance, and docs drift",
    workflow: resolve(FIXTURES, "release-contract-drift/release.yml"),
    checks: ["release-workflow-contract"],
    mentions: [
      "v5.0.0 SHA",
      "immutable tag",
      "explicit repository context",
      "draft-aware release lookup",
      "current candidate runner record",
      "`cog-release`",
      "dispatch `docs.yml`",
      "proposed PR head",
      "`coglint-plugins`",
    ],
  },
  {
    name: "self-hosted job with no guard",
    workflow: resolve(FIXTURES, "guard-removed.yml"),
    checks: ["self-hosted-guard"],
    mentions: ["`host-tests`", "`lint`", "github.repository == 'skeswa/cog'"],
  },
  {
    name: "guard ORed away, and a guard missing its fork clause",
    workflow: resolve(FIXTURES, "guard-bypassed.yml"),
    checks: ["self-hosted-guard"],
    mentions: [
      "`host-tests`",
      "top-level `||`",
      "`partial-guard`",
      "github.event.pull_request.head.repo.full_name == github.repository",
    ],
  },
  {
    name: "unknown runner labels fail closed",
    workflow: resolve(FIXTURES, "unlabelled-runner.yml"),
    checks: ["self-hosted-guard"],
    mentions: ["`mini-tests`", "cog-mac-mini-1", "`matrix-tests`", "computed label"],
  },
  {
    name: "write scopes, write-all, and a missing block",
    workflow: resolve(FIXTURES, "over-broad-permissions.yml"),
    checks: ["least-privilege-permissions"],
    mentions: ["contents: write", "id-token: write", "write-all", "no effective `permissions:`"],
  },
  {
    name: "the Pages deploy exception is granted, and only to its own job",
    workflow: resolve(FIXTURES, "docs.yml"),
    checks: [],
  },
  {
    name: "the Pages exception does not stretch to extra scopes, other jobs, or the mini",
    workflow: resolve(FIXTURES, "pages-exception-abused/docs.yml"),
    checks: ["least-privilege-permissions", "self-hosted-guard"],
    mentions: ["`deploy`", "contents: write", "`smuggler`", "`deploy-mini`", "pages: write"],
  },
  {
    name: "tags, branches, short and uppercase SHAs, and an unpinned image",
    workflow: resolve(FIXTURES, "unpinned-action.yml"),
    checks: ["sha-pinned-actions"],
    mentions: [
      "actions/checkout@v7",
      "jdx/mise-action@main",
      "short SHA",
      "lowercase",
      "no `@` reference",
      "docker://ghcr.io/skeswa/notes:latest",
      "release.yml@v3",
    ],
    // The local action and the digest-pinned image are exempt.
    absent: ["scrub", "@sha256:14e0a7b0"],
  },
  {
    name: "the pull_request_target trigger",
    workflow: resolve(FIXTURES, "pull-request-target.yml"),
    checks: ["no-pull-request-target"],
    mentions: ["use `pull_request`"],
  },
  {
    name: "mentioning pull_request_target in prose is not using it",
    workflow: resolve(FIXTURES, "mentions-pull-request-target.yml"),
    checks: [],
  },
  {
    name: "checkout leaving the token behind",
    workflow: resolve(FIXTURES, "credentials-persisted.yml"),
    checks: ["credential-hygiene"],
    mentions: ["`build`", "`deploy`", "persist-credentials"],
  },
  {
    name: "unbounded and zero job timeouts",
    workflow: resolve(FIXTURES, "no-timeout.yml"),
    checks: ["job-timeout"],
    mentions: ["`build`", "`soak`", "timeout-minutes"],
  },
];

/** @param {string} workflow */
function runChecker(workflow) {
  const result = spawnSync(process.execPath, [CHECKER, workflow], { encoding: "utf8" });
  if (result.error !== undefined && result.error !== null) throw result.error;
  return {
    status: result.status,
    output: `${result.stdout ?? ""}${result.stderr ?? ""}`,
  };
}

/** @param {string} output */
function reportedChecks(output) {
  return [...new Set([...output.matchAll(/error\[([a-z-]+)\]/g)].map((match) => match[1]))].sort();
}

/** @param {Case} testCase */
function evaluate(testCase) {
  const { status, output } = runChecker(testCase.workflow);
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
    if (!output.includes(mention)) failures.push(`diagnostics never mention \`${mention}\``);
  }
  for (const mention of testCase.absent ?? []) {
    if (output.includes(mention)) failures.push(`diagnostics should not mention \`${mention}\``);
  }
  return { failures, output };
}

function main() {
  let failed = 0;
  for (const testCase of CASES) {
    const workflow = relative(REPO_ROOT, testCase.workflow);
    const { failures, output } = evaluate(testCase);
    if (failures.length === 0) {
      const expectation =
        testCase.checks.length === 0 ? "clean" : `fires ${testCase.checks.join(", ")}`;
      process.stdout.write(`ok   ${testCase.name} (${workflow}) — ${expectation}\n`);
      continue;
    }
    failed += 1;
    process.stdout.write(`FAIL ${testCase.name} (${workflow})\n`);
    for (const failure of failures) process.stdout.write(`       ${failure}\n`);
    for (const line of output.trimEnd().split("\n")) {
      process.stdout.write(`       | ${line}\n`);
    }
  }

  const total = CASES.length;
  if (failed > 0) {
    process.stdout.write(`\ntest-workflows: FAILED ${failed}/${total} case(s)\n`);
    process.exit(1);
  }
  process.stdout.write(`\ntest-workflows: PASSED ${total}/${total} cases\n`);
}

main();
