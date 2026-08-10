#!/usr/bin/env node
// Validates the GitHub Actions workflow contract.
//
//     node tools/check-workflows.mjs [path ...] [--json]
//
// Defaults to every `*.yml` and `*.yaml` file in `.github/workflows`. Paths
// may be workflow files or directories of them, which is how the fixtures in
// `tools/fixtures/workflows` are checked one at a time. Exits 0 with a
// one-line summary when every check passes, and non-zero with one greppable
// `error[<check>]` line per failure otherwise.
//
// The checks (`tools/lib/workflows/checks.mjs`, in registry order):
//
//   no-pull-request-target       no workflow uses the `pull_request_target`
//                                trigger, read from the parsed `on:` key so a
//                                comment mentioning it is not a use of it
//   self-hosted-guard            every job on a self-hosted runner carries the
//                                same-repo guard, on every branch of a
//                                top-level `||`
//   least-privilege-permissions  every job has an effective `permissions:`
//                                block no broader than `contents: read`
//   credential-hygiene           every `actions/checkout` sets
//                                `persist-credentials: false`
//   job-timeout                  every job sets a positive `timeout-minutes`
//   sha-pinned-actions           every `uses:` names a full-length lowercase
//                                commit SHA
//
// Malformed YAML is reported the same way, under `yaml-parse`, as is a file
// with no readable job: every check above is a check on jobs, so a document
// the reader got nothing out of must fail rather than pass vacuously.
//
// The policy constants — the repository name the guard must match, the
// self-hosted runner labels, and the hosted-image pattern everything else
// fails closed against — sit in one clearly marked block at the top of
// `tools/lib/workflows/checks.mjs`.

import { readdirSync, readFileSync, statSync } from "node:fs";
import { join, relative, resolve } from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

import { runChecks } from "./lib/workflows/checks.mjs";
import { readWorkflow } from "./lib/workflows/model.mjs";

const REPO_ROOT = resolve(fileURLToPath(new URL("..", import.meta.url)));
const DEFAULT_DIRECTORY = resolve(REPO_ROOT, ".github/workflows");

const USAGE = "usage: node tools/check-workflows.mjs [path ...] [--json]\n";

/** @param {string[]} argv */
function parseArgs(argv) {
  let json = false;
  /** @type {string[]} */
  const paths = [];

  for (const arg of argv) {
    if (arg === "--json") {
      json = true;
      continue;
    }
    if (arg === "--help" || arg === "-h") {
      process.stdout.write(USAGE);
      process.exit(0);
    }
    if (arg.startsWith("-")) {
      process.stderr.write(`check-workflows: unknown option ${arg}\n`);
      process.exit(2);
    }
    paths.push(resolve(arg));
  }

  return { paths: paths.length === 0 ? [DEFAULT_DIRECTORY] : paths, json };
}

/** @param {string} path */
function isWorkflowFile(path) {
  return path.endsWith(".yml") || path.endsWith(".yaml");
}

/**
 * Expands the requested paths into a sorted list of workflow files.
 *
 * @param {string[]} paths
 */
function collect(paths) {
  /** @type {string[]} */
  const files = [];
  for (const path of paths) {
    let stats;
    try {
      stats = statSync(path);
    } catch (error) {
      process.stderr.write(`check-workflows: cannot read ${path}: ${error.message}\n`);
      process.exit(2);
    }
    if (stats.isDirectory()) {
      for (const name of readdirSync(path).sort()) {
        if (isWorkflowFile(name)) files.push(join(path, name));
      }
      continue;
    }
    files.push(path);
  }
  return [...new Set(files)].sort();
}

/** Repo-relative path when the file is inside the repo, absolute otherwise. */
function displayPath(path) {
  const rel = relative(REPO_ROOT, path);
  if (rel.length === 0 || rel.startsWith("..")) return path;
  return rel;
}

/** @param {{path: string, line: number, check: string, message: string}} item */
function formatDiagnostic(item) {
  return `${displayPath(item.path)}:${item.line}: error[${item.check}]: ${item.message}`;
}

/** @param {string} path */
function read(path) {
  try {
    return readFileSync(path, "utf8");
  } catch (error) {
    process.stderr.write(`check-workflows: cannot read ${path}: ${error.message}\n`);
    process.exit(2);
  }
}

function main() {
  const { paths, json } = parseArgs(process.argv.slice(2));
  const files = collect(paths);

  if (files.length === 0) {
    process.stderr.write(
      `check-workflows: no workflow files under ${paths.map(displayPath).join(", ")}\n`,
    );
    process.exit(2);
  }

  const workflows = files.map((file) => readWorkflow(file, read(file)));
  const { diagnostics: checkDiagnostics, checkNames } = runChecks(workflows);
  const diagnostics = [
    ...workflows.flatMap((workflow) => workflow.diagnostics),
    ...checkDiagnostics,
  ].sort(
    (a, b) => a.path.localeCompare(b.path) || a.line - b.line || a.check.localeCompare(b.check),
  );

  const jobCount = workflows.reduce((total, workflow) => total + workflow.jobs.length, 0);
  const stepCount = workflows.reduce(
    (total, workflow) => total + workflow.jobs.reduce((sum, job) => sum + job.steps.length, 0),
    0,
  );

  if (json) {
    process.stdout.write(
      `${JSON.stringify(
        {
          workflows: workflows.map((workflow) => ({
            path: displayPath(workflow.path),
            triggers: workflow.triggers.map((trigger) => trigger.name),
            jobs: workflow.jobs.map((job) => job.id),
          })),
          checks: checkNames,
          diagnostics: diagnostics.map((item) => ({
            check: item.check,
            path: displayPath(item.path),
            line: item.line,
            job: item.job ?? null,
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
    for (const item of diagnostics) process.stderr.write(`${formatDiagnostic(item)}\n`);
    const failed = [...new Set(diagnostics.map((item) => item.check))].sort();
    process.stderr.write(
      `check-workflows: FAILED ${files.length} workflow(s) — ` +
        `${diagnostics.length} problem(s) in ${failed.length} check(s): ${failed.join(", ")}\n`,
    );
    process.exit(1);
  }

  process.stdout.write(
    `check-workflows: OK ${files.map(displayPath).join(" ")} — ` +
      `${files.length} workflow(s), ${jobCount} job(s), ${stepCount} step(s); ` +
      `${checkNames.length} checks passed: ${checkNames.join(", ")}\n`,
  );
}

main();
