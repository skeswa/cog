#!/usr/bin/env node

// Builds the two native CogLint host executables, assembles the SwiftPM
// artifact bundle, and records the checksum consumers put in binaryTarget.
//
// Usage: `build-coglint-artifact.mjs [version]`

import { spawnSync } from "node:child_process";
import { chmodSync, copyFileSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { basename, join } from "node:path";
import { fileURLToPath } from "node:url";
import { currentVersion } from "./lib/version.mjs";

/** The repository root, resolved from this script so cwd never matters. */
const REPO_ROOT = fileURLToPath(new URL("..", import.meta.url));

/** The isolated source package from which release executables are built. */
const LINT_PACKAGE = join(REPO_ROOT, "swift", "Lint");

/** Generated artifacts stay beside their isolated development package. */
const ARTIFACTS_DIRECTORY = join(LINT_PACKAGE, "Artifacts");

/** SwiftPM shares dependency checkouts while separating triple build products. */
const BUILD_DIRECTORY = join(LINT_PACKAGE, ".build", "artifact-release");

/** The exact bundle and release-asset names accepted by lint.md section 7. */
const BUNDLE_NAME = "CogLintBinary.artifactbundle";
const ARCHIVE_NAME = `${BUNDLE_NAME}.zip`;

/** Native variants accepted for the first CogLint release. */
const VARIANTS = [
  {
    architecture: "arm64",
    buildTriple: "arm64-apple-macosx14.0",
    supportedTriple: "arm64-apple-macosx",
    directory: "coglint-arm64-apple-macosx",
  },
  {
    architecture: "x86_64",
    buildTriple: "x86_64-apple-macosx14.0",
    supportedTriple: "x86_64-apple-macosx",
    directory: "coglint-x86_64-apple-macosx",
  },
];

main(process.argv.slice(2));

/** Builds, validates, bundles, archives, and checksums one CogLint version. */
function main(arguments_) {
  if (process.platform !== "darwin") {
    fail("CogLint release artifacts must be built on macOS");
  }
  if (arguments_.length > 1) {
    fail("usage: build-coglint-artifact.mjs [version]");
  }

  const version = arguments_[0] ?? currentVersion();
  if (!/^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$/.test(version)) {
    fail(`invalid semantic version: ${version}`);
  }

  const bundlePath = join(ARTIFACTS_DIRECTORY, BUNDLE_NAME);
  const archivePath = join(ARTIFACTS_DIRECTORY, ARCHIVE_NAME);
  const checksumPath = `${archivePath}.checksum`;

  rmSync(BUILD_DIRECTORY, { force: true, recursive: true });
  rmSync(bundlePath, { force: true, recursive: true });
  rmSync(archivePath, { force: true });
  rmSync(checksumPath, { force: true });
  mkdirSync(bundlePath, { recursive: true });

  for (const variant of VARIANTS) {
    console.log(`\n==> Building coglint for ${variant.buildTriple}`);
    run(
      "swift",
      [
        "build",
        "--package-path",
        LINT_PACKAGE,
        "--scratch-path",
        BUILD_DIRECTORY,
        "--configuration",
        "release",
        "--product",
        "coglint",
        "--triple",
        variant.buildTriple,
      ],
      { stdio: "inherit" },
    );

    const binPath = run(
      "swift",
      [
        "build",
        "--package-path",
        LINT_PACKAGE,
        "--scratch-path",
        BUILD_DIRECTORY,
        "--configuration",
        "release",
        "--triple",
        variant.buildTriple,
        "--show-bin-path",
      ],
      { encoding: "utf8" },
    ).stdout.trim();
    const sourceExecutable = join(binPath, "coglint");
    validateExecutable(sourceExecutable, variant);

    const destinationDirectory = join(bundlePath, variant.directory, "bin");
    const destinationExecutable = join(destinationDirectory, "coglint");
    mkdirSync(destinationDirectory, { recursive: true });
    copyFileSync(sourceExecutable, destinationExecutable);
    chmodSync(destinationExecutable, 0o755);
  }

  const metadata = {
    schemaVersion: "1.0",
    artifacts: {
      coglint: {
        type: "executable",
        version,
        variants: VARIANTS.map((variant) => ({
          path: `${variant.directory}/bin/coglint`,
          supportedTriples: [variant.supportedTriple],
        })),
      },
    },
  };
  writeFileSync(join(bundlePath, "info.json"), `${JSON.stringify(metadata, null, 2)}\n`);

  console.log(`\n==> Archiving ${ARCHIVE_NAME}`);
  run("zip", ["-X", "-q", "-r", archivePath, basename(bundlePath)], {
    cwd: ARTIFACTS_DIRECTORY,
    stdio: "inherit",
  });

  const checksum = run("swift", ["package", "compute-checksum", archivePath], {
    encoding: "utf8",
  }).stdout.trim();
  if (!/^[0-9a-f]{64}$/.test(checksum)) {
    fail(`SwiftPM returned an invalid checksum: ${JSON.stringify(checksum)}`);
  }
  writeFileSync(checksumPath, `${checksum}\n`);

  console.log(`==> Bundle: ${bundlePath}`);
  console.log(`==> Archive: ${archivePath}`);
  console.log(`==> SwiftPM checksum: ${checksum}`);
}

/** Proves one built executable is native-only and retains the macOS 14 floor. */
function validateExecutable(executable, variant) {
  const architectures = run("lipo", ["-archs", executable], { encoding: "utf8" }).stdout.trim();
  if (architectures !== variant.architecture) {
    fail(
      `${variant.buildTriple} produced architectures ${JSON.stringify(architectures)}, expected only ${variant.architecture}`,
    );
  }

  const loadCommands = run("vtool", ["-show-build", executable], {
    encoding: "utf8",
  }).stdout;
  if (!/^\s*minos 14\.0$/m.test(loadCommands)) {
    fail(`${variant.buildTriple} does not declare macOS 14.0 as its deployment target`);
  }
}

/** Runs one required subprocess and preserves enough context to diagnose it. */
function run(command, arguments_, options = {}) {
  const result = spawnSync(command, arguments_, {
    maxBuffer: 32 * 1024 * 1024,
    ...options,
  });
  if (result.error !== undefined) {
    fail(`could not run ${command}: ${result.error.message}`);
  }
  if (result.signal !== null && result.signal !== undefined) {
    fail(`${command} was killed by ${result.signal}`);
  }
  if (result.status !== 0) {
    fail(`${command} exited with status ${result.status}`);
  }
  return result;
}

/** Reports a pipeline failure without leaving a plausible partial success. */
function fail(message) {
  console.error(`error: coglint artifact build: ${message}`);
  process.exit(1);
}
