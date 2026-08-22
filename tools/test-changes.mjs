#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import { mkdtempSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { lintCommits } from "./check-changes.mjs";
import { collectGitCommits, collectJjRevisions, commitsForGitHubEvent } from "./lib/changes.mjs";

const REPO_ROOT = fileURLToPath(new URL("..", import.meta.url));
const FIXTURES = join(REPO_ROOT, "tools", "fixtures", "changes");

main();

/** Proves message syntax, maintainer footers, and both supported VCS ranges. */
function main() {
  verifyPinnedTooling();
  verifyMessageFixtures();
  verifyGitRange();
  verifyJjRange();
  console.log("test-changes: all Conventional Commit fixtures passed");
}

/** Commitlint's executable and conventional ruleset are exact lockfile inputs. */
function verifyPinnedTooling() {
  const packageManifest = JSON.parse(readFileSync(join(REPO_ROOT, "package.json"), "utf8"));
  const lockfile = JSON.parse(readFileSync(join(REPO_ROOT, "package-lock.json"), "utf8"));
  const expected = {
    "@commitlint/cli": "21.2.1",
    "@commitlint/config-conventional": "21.2.0",
  };
  for (const [name, version] of Object.entries(expected)) {
    if (
      packageManifest.devDependencies?.[name] !== version ||
      lockfile.packages?.[`node_modules/${name}`]?.version !== version
    ) {
      fail(`${name} is not pinned to ${version} in both package files`);
    }
  }
}

function fixtureMessages(kind) {
  return readdirSync(join(FIXTURES, kind))
    .sort()
    .map((name) => ({
      id: `${kind}/${name}`,
      authorName: "Sandile Keswa",
      authorEmail: "me@sandile.io",
      message: readFileSync(join(FIXTURES, kind, name), "utf8").trimEnd(),
    }));
}

/** Valid and invalid syntax includes breaking notes and Release Please secondary messages. */
function verifyMessageFixtures() {
  const validFailures = lintCommits(fixtureMessages("valid"), {});
  if (validFailures.length > 0) fail(`valid messages failed:\n${validFailures.join("\n")}`);

  for (const commit of fixtureMessages("invalid")) {
    if (lintCommits([commit], {}).length === 0) fail(`${commit.id} unexpectedly passed`);
  }

  const releaseAs = fixtureMessages("valid").find((commit) => commit.id.endsWith("secondary.txt"));
  const unauthorized = {
    ...releaseAs,
    id: "release-as/non-maintainer",
    authorEmail: "dev@example.com",
  };
  const failures = lintCommits([unauthorized], {});
  if (!failures.some((failure) => failure.includes("reserved for maintainer"))) {
    fail("a non-maintainer Release-As footer unexpectedly passed");
  }
}

/** Builds a real Git range and proves every commit after the base is returned oldest-first. */
function verifyGitRange() {
  withScratch("changes-git-", (directory) => {
    run("git", ["init", "-q"], directory);
    run("git", ["config", "user.name", "Sandile Keswa"], directory);
    run("git", ["config", "user.email", "me@sandile.io"], directory);
    commitFile(directory, "base", "chore: establish fixture base");
    const base = run("git", ["rev-parse", "HEAD"], directory).stdout.trim();
    commitFile(directory, "feature", "feat(swift): add range fixture");
    commitFile(directory, "fix", "fix: prove the complete push range");
    const head = run("git", ["rev-parse", "HEAD"], directory).stdout.trim();
    const commits = collectGitCommits(directory, base, head);
    if (commits.length !== 2 || commits[0].message !== "feat(swift): add range fixture") {
      fail("Git range did not return the two post-base commits oldest-first");
    }
    const failures = lintCommits(commits, {});
    if (failures.length > 0) fail(`Git range failed lint:\n${failures.join("\n")}`);

    const pullRequest = commitsForGitHubEvent(directory, "pull_request", {
      pull_request: { base: { sha: base }, head: { sha: head } },
    });
    const push = commitsForGitHubEvent(directory, "push", { before: base, after: head });
    if (
      JSON.stringify(pullRequest) !== JSON.stringify(commits) ||
      JSON.stringify(push) !== JSON.stringify(commits)
    ) {
      fail("GitHub PR and push payloads did not resolve the authoritative Git range");
    }

    run("git", ["commit", "-q", "--allow-empty", "--allow-empty-message", "-m", ""], directory);
    const emptyHead = run("git", ["rev-parse", "HEAD"], directory).stdout.trim();
    const authoritative = collectGitCommits(directory, head, emptyHead);
    if (
      !lintCommits(authoritative, {}).some((failure) => failure.includes("description is empty"))
    ) {
      fail("an empty Git commit description did not fail authoritative range linting");
    }
  });
}

/** Builds a colocated jj repository and proves `main..@` includes child descriptions only. */
function verifyJjRange() {
  withScratch("changes-jj-", (directory) => {
    run("jj", ["git", "init", "--colocate", "."], directory);
    writeFileSync(join(directory, "fixture.txt"), "base\n");
    run("jj", ["commit", "-m", "chore: establish fixture base"], directory);
    run("jj", ["bookmark", "create", "main", "-r", "@-"], directory);
    writeFileSync(join(directory, "fixture.txt"), "feature\n");
    run("jj", ["commit", "-m", "feat(swift): add jj range fixture"], directory);
    run("jj", ["new"], directory);
    writeFileSync(join(directory, "fixture.txt"), "fix\n");
    run("jj", ["describe", "-m", "fix: include the working-copy description"], directory);
    const commits = collectJjRevisions(directory);
    if (
      commits.length !== 2 ||
      commits[1].message !== "fix: include the working-copy description"
    ) {
      fail("jj range did not return both described child revisions oldest-first");
    }
    const failures = lintCommits(commits, {});
    if (failures.length > 0) fail(`jj range failed lint:\n${failures.join("\n")}`);
  });
}

function commitFile(directory, value, message) {
  writeFileSync(join(directory, "fixture.txt"), `${value}\n`);
  run("git", ["add", "fixture.txt"], directory);
  run("git", ["commit", "-q", "-m", message], directory);
}

function withScratch(prefix, operation) {
  const directory = mkdtempSync(join(tmpdir(), prefix));
  mkdirSync(directory, { recursive: true });
  try {
    operation(directory);
  } finally {
    rmSync(directory, { force: true, recursive: true });
  }
}

function run(command, arguments_, cwd) {
  const result = spawnSync(command, arguments_, { cwd, encoding: "utf8" });
  if (result.error !== undefined) throw result.error;
  if (result.status !== 0) fail(`${command} ${arguments_.join(" ")} failed:\n${result.stderr}`);
  return result;
}

function fail(message) {
  console.error(`error: test-changes: ${message}`);
  process.exit(1);
}
