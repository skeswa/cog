#!/usr/bin/env node

// Builds the two native CogLint host executables, assembles the SwiftPM
// artifact bundle, and records the checksum consumers put in binaryTarget.
// The bundle names, paths, and variant table live in
// `lib/coglint-artifact.mjs`, shared with the generator and the pipeline
// tests.
//
// Usage: `build-coglint-artifact.mjs [version]`

import { chmodSync, copyFileSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { basename, join } from "node:path";
import {
  ARCHIVE_NAME,
  ARCHIVE_PATH,
  ARTIFACTS_DIRECTORY,
  BUNDLE_PATH,
  CHECKSUM_PATH,
  LINT_PACKAGE,
  SEMANTIC_VERSION,
  VARIANTS,
  makeRunners,
} from "./lib/coglint-artifact.mjs";
import { currentVersion } from "./lib/version.mjs";

/** SwiftPM shares dependency checkouts while separating triple build products. */
const BUILD_DIRECTORY = join(LINT_PACKAGE, ".build", "artifact-release");

const { runSuccessful: run } = makeRunners(fail);

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
  if (!SEMANTIC_VERSION.test(version)) {
    fail(`invalid semantic version: ${version}`);
  }

  rmSync(BUILD_DIRECTORY, { force: true, recursive: true });
  rmSync(BUNDLE_PATH, { force: true, recursive: true });
  rmSync(ARCHIVE_PATH, { force: true });
  rmSync(CHECKSUM_PATH, { force: true });
  mkdirSync(BUNDLE_PATH, { recursive: true });

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

    const destinationDirectory = join(BUNDLE_PATH, variant.directory, "bin");
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
          path: variant.relativePath,
          supportedTriples: [variant.supportedTriple],
        })),
      },
    },
  };
  writeFileSync(join(BUNDLE_PATH, "info.json"), `${JSON.stringify(metadata, null, 2)}\n`);

  console.log(`\n==> Archiving ${ARCHIVE_NAME}`);
  run("zip", ["-X", "-q", "-r", ARCHIVE_PATH, basename(BUNDLE_PATH)], {
    cwd: ARTIFACTS_DIRECTORY,
    stdio: "inherit",
  });

  const checksum = run("swift", ["package", "compute-checksum", ARCHIVE_PATH], {
    encoding: "utf8",
  }).stdout.trim();
  if (!/^[0-9a-f]{64}$/.test(checksum)) {
    fail(`SwiftPM returned an invalid checksum: ${JSON.stringify(checksum)}`);
  }
  writeFileSync(CHECKSUM_PATH, `${checksum}\n`);

  console.log(`==> Bundle: ${BUNDLE_PATH}`);
  console.log(`==> Archive: ${ARCHIVE_PATH}`);
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

/** Reports a pipeline failure without leaving a plausible partial success. */
function fail(message) {
  console.error(`error: coglint artifact build: ${message}`);
  process.exit(1);
}
