#!/usr/bin/env node
// Selects the exact Xcode version and build pinned by a macOS CI workflow.
//
// The self-hosted and GitHub-hosted runners spell application paths
// differently, so selection is based on each bundle's reported toolchain. The
// chosen DEVELOPER_DIR is job-scoped through GITHUB_ENV; this never mutates the
// host-wide xcode-select setting.

import { spawnSync } from "node:child_process";
import { appendFileSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";
import process from "node:process";

const applicationsDirectory = process.env.COG_XCODE_APPLICATIONS_DIRECTORY ?? "/Applications";
const expectedVersion = requiredEnvironment("COG_XCODE_VERSION");
const expectedBuild = requiredEnvironment("COG_XCODE_BUILD");

/** Returns a required environment value or exits with a configuration error. */
function requiredEnvironment(name) {
  const value = process.env[name];
  if (value === undefined || value.length === 0) {
    process.stderr.write(`select-xcode: ${name} is required\n`);
    process.exit(2);
  }
  return value;
}

/** Runs a tool and returns its trimmed standard output. */
function capture(command, args, environment = process.env) {
  const result = spawnSync(command, args, {
    encoding: "utf8",
    env: environment,
  });
  if (result.status !== 0) return null;
  return result.stdout.trim();
}

/** Reads Xcode's version and build through its own selected developer dir. */
function inspect(application) {
  const developerDirectory = join(application, "Contents/Developer");
  const environment = { ...process.env, DEVELOPER_DIR: developerDirectory };
  const output = capture("/usr/bin/xcodebuild", ["-version"], environment);
  if (output === null) return { application, developerDirectory, version: null, build: null };
  const version = output.match(/^Xcode (.+)$/m)?.[1] ?? null;
  const build = output.match(/^Build version (.+)$/m)?.[1] ?? null;
  return { application, developerDirectory, version, build };
}

let applications;
try {
  applications = readdirSync(applicationsDirectory)
    .filter((name) => name.startsWith("Xcode") && name.endsWith(".app"))
    .map((name) => join(applicationsDirectory, name))
    .filter((path) => statSync(path).isDirectory())
    .sort();
} catch (error) {
  process.stderr.write(`select-xcode: cannot inspect ${applicationsDirectory}: ${error.message}\n`);
  process.exit(2);
}

const toolchains = applications.map(inspect);
process.stdout.write("Installed Xcodes:\n");
if (toolchains.length === 0) process.stdout.write("    (none)\n");
for (const toolchain of toolchains) {
  const identity =
    toolchain.version === null
      ? "unavailable"
      : `${toolchain.version} (${toolchain.build ?? "unknown"})`;
  process.stdout.write(`    ${toolchain.application} -> ${identity}\n`);
}

const selected = toolchains.find(
  (toolchain) => toolchain.version === expectedVersion && toolchain.build === expectedBuild,
);
if (selected === undefined) {
  process.stderr.write(
    `::error title=Pinned Xcode missing::Xcode ${expectedVersion} (${expectedBuild}) is not installed. Update the workflow pin and docs/maintainers/ci.md together.\n`,
  );
  process.exit(1);
}

const githubEnvironment = requiredEnvironment("GITHUB_ENV");
appendFileSync(githubEnvironment, `DEVELOPER_DIR=${selected.developerDirectory}\n`);

const selectedEnvironment = { ...process.env, DEVELOPER_DIR: selected.developerDirectory };
for (const [command, args] of [
  ["/usr/bin/xcodebuild", ["-version"]],
  ["/usr/bin/swift", ["--version"]],
]) {
  const result = spawnSync(command, args, { env: selectedEnvironment, stdio: "inherit" });
  if (result.error !== undefined) throw result.error;
  if (result.status !== 0) process.exit(result.status ?? 1);
}
