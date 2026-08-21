#!/usr/bin/env node
// Compares the supported Swift products with the most recent release tag.
//
//     node tools/check-swift-api.mjs [baseline]
//
// `COG_API_BASELINE` is the environment counterpart of the optional argument.
// When neither is present, the highest semantic-version tag is the baseline.
// The candidate always uses Cog's shipping representation selectors so a
// developer's benchmark environment cannot accidentally change the API being
// checked.

import { spawnSync } from "node:child_process";
import process from "node:process";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";

const REPO_ROOT = resolve(fileURLToPath(new URL("..", import.meta.url)));
const USAGE = "usage: node tools/check-swift-api.mjs [baseline]\n";

/** Runs a command whose standard output is needed by the checker. */
function capture(command, args) {
  const result = spawnSync(command, args, {
    cwd: REPO_ROOT,
    encoding: "utf8",
  });
  if (result.status !== 0) {
    process.stderr.write(result.stderr || `${command} failed with status ${result.status}\n`);
    process.exit(result.status ?? 1);
  }
  return result.stdout.trim();
}

/** Parses the one optional baseline argument. */
function parseArgs(args) {
  if (args.includes("--help") || args.includes("-h")) {
    process.stdout.write(USAGE);
    process.exit(0);
  }
  if (args.length > 1 || args.some((arg) => arg.startsWith("-"))) {
    process.stderr.write(USAGE);
    process.exit(2);
  }
  return args[0] ?? process.env.COG_API_BASELINE ?? latestReleaseTag();
}

/** Returns the newest stable release tag known to the checkout. */
function latestReleaseTag() {
  const tags = capture("git", ["tag", "--list", "[0-9]*.[0-9]*.[0-9]*", "--sort=-version:refname"]);
  const [latest] = tags.split("\n").filter(Boolean);
  if (latest === undefined) {
    process.stderr.write(
      "check-swift-api: no semantic-version release tag is available; pass a baseline explicitly\n",
    );
    process.exit(2);
  }
  return latest;
}

const baseline = parseArgs(process.argv.slice(2));
capture("git", ["rev-parse", "--verify", "--quiet", `${baseline}^{commit}`]);

const environment = { ...process.env };
environment.COG_TEST_CORE = "simple";
environment.COG_TEST_VALUE_REFERENCE_LAYOUT = "inline";
delete environment.COG_TEST_EDGE;
delete environment.COG_DOCC;

process.stdout.write(`Comparing Cog and CogTesting APIs with ${baseline}\n`);
const result = spawnSync(
  "swift",
  [
    "package",
    "--scratch-path",
    resolve(REPO_ROOT, ".build/api-compatibility"),
    "diagnose-api-breaking-changes",
    baseline,
    "--products",
    "Cog",
    "CogTesting",
  ],
  {
    cwd: REPO_ROOT,
    env: environment,
    stdio: "inherit",
  },
);

if (result.error !== undefined) throw result.error;
if (result.signal !== null) {
  process.stderr.write(`check-swift-api: swift terminated by ${result.signal}\n`);
  process.exit(1);
}
process.exit(result.status ?? 1);
