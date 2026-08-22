#!/usr/bin/env node

// Lints every revision description that can land on main. Local runs read
// non-empty jj descriptions in `main..@`; GitHub runs use the exact PR or push
// before/after SHAs from the event payload and do not trust changed paths.

import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import {
  collectGitAncestors,
  collectGitCommits,
  collectJjRevisions,
  commitsForGitHubEvent,
  hasReleaseAs,
  releaseAsMaintainer,
} from "./lib/changes.mjs";

/** Repository-owned configuration and executable locations. */
const REPO_ROOT = fileURLToPath(new URL("..", import.meta.url));
const CONFIG = join(REPO_ROOT, "commitlint.config.mjs");
const COMMITLINT = join(REPO_ROOT, "node_modules", ".bin", "commitlint");

/** Lints collected messages and enforces the maintainer-only release override. */
export function lintCommits(commits, environment = process.env) {
  const failures = [];
  for (const commit of commits) {
    if (commit.message.trim() === "") {
      failures.push(`${commit.id}: revision description is empty`);
      continue;
    }
    if (hasReleaseAs(commit.message) && !releaseAsMaintainer(commit, environment)) {
      failures.push(`${commit.id}: Release-As is reserved for maintainer-authored revisions`);
    }
    const result = spawnSync(COMMITLINT, ["--config", CONFIG, "--color", "false"], {
      cwd: REPO_ROOT,
      encoding: "utf8",
      env: { ...process.env, NO_COLOR: "1" },
      input: `${commit.message}\n`,
    });
    if (result.error !== undefined) throw result.error;
    if (result.status !== 0) {
      failures.push(`${commit.id}:\n${`${result.stdout}${result.stderr}`.trim()}`);
    }
  }
  return failures;
}

/** Chooses explicit test ranges, a GitHub event range, or the local jj range. */
function collect(arguments_) {
  if (arguments_[0] === "--git" && arguments_.length === 3) {
    return collectGitCommits(process.cwd(), arguments_[1], arguments_[2]);
  }
  if (arguments_[0] === "--git-all" && arguments_.length === 2) {
    return collectGitAncestors(process.cwd(), arguments_[1]);
  }
  if (arguments_[0] === "--jj" && arguments_.length === 2) {
    return collectJjRevisions(process.cwd(), arguments_[1]);
  }
  if (arguments_.length !== 0) {
    throw new Error("usage: check-changes.mjs [--git from to | --git-all to | --jj revset]");
  }
  if (process.env.GITHUB_ACTIONS === "true") {
    const event = JSON.parse(readFileSync(process.env.GITHUB_EVENT_PATH, "utf8"));
    return commitsForGitHubEvent(REPO_ROOT, process.env.GITHUB_EVENT_NAME, event);
  }
  return collectJjRevisions(REPO_ROOT);
}

function main(arguments_) {
  const commits = collect(arguments_);
  const failures = lintCommits(commits);
  if (failures.length > 0) {
    for (const failure of failures)
      process.stderr.write(`error[conventional-commits] ${failure}\n`);
    process.exit(1);
  }
  process.stdout.write(`changes:check: ${commits.length} revision description(s) conform\n`);
}

if (process.argv[1] !== undefined && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main(process.argv.slice(2));
}
