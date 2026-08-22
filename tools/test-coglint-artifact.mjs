#!/usr/bin/env node

// Builds the CogLint artifact and proves SwiftPM selects and executes each
// metadata variant when the same consumer runs under each supported host.

import { spawnSync } from "node:child_process";
import { cpSync, mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { currentVersion } from "./lib/version.mjs";

/** The repository root, resolved from this script so cwd never matters. */
const REPO_ROOT = fileURLToPath(new URL("..", import.meta.url));

/** Generated bundle and archive paths owned by the artifact builder. */
const ARTIFACTS_DIRECTORY = join(REPO_ROOT, "swift", "Lint", "Artifacts");
const BUNDLE_NAME = "CogLintBinary.artifactbundle";
const BUNDLE_PATH = join(ARTIFACTS_DIRECTORY, BUNDLE_NAME);
const ARCHIVE_PATH = `${BUNDLE_PATH}.zip`;
const CHECKSUM_PATH = `${ARCHIVE_PATH}.checksum`;
const VERSION = currentVersion();

/** Metadata selectors and exact contained paths LINT-19 promises. */
const VARIANTS = [
  {
    architecture: "arm64",
    supportedTriple: "arm64-apple-macosx",
    relativePath: "coglint-arm64-apple-macosx/bin/coglint",
  },
  {
    architecture: "x86_64",
    supportedTriple: "x86_64-apple-macosx",
    relativePath: "coglint-x86_64-apple-macosx/bin/coglint",
  },
];

main(parseOptions(process.argv.slice(2)));

/** Runs the complete build, structure, checksum, and host-selection proof. */
function main(options) {
  if (process.platform !== "darwin") {
    fail("LINT-19 requires a macOS host");
  }
  if (!options.fromArchive && process.arch !== "arm64") {
    fail("building LINT-19 requires the accepted Apple Silicon release host");
  }

  if (options.fromArchive) {
    validateArchiveAndChecksum();
    materializeBundleFromArchive();
  } else {
    run(process.execPath, [join(REPO_ROOT, "tools", "build-coglint-artifact.mjs")], {
      stdio: "inherit",
    });
  }
  validateMetadata();
  if (!options.fromArchive) validateArchiveAndChecksum();

  const swiftExecutable = run("xcrun", ["--find", "swift"], {
    encoding: "utf8",
  }).stdout.trim();

  const probeDirectory = mkdtempSync(join(tmpdir(), "coglint-artifact-selection-"));
  process.on("exit", () => rmSync(probeDirectory, { force: true, recursive: true }));
  writeProbePackage(probeDirectory);

  for (const variant of options.variants) {
    validateHostSelection(probeDirectory, swiftExecutable, variant);
  }

  const hosts = options.variants.map((variant) => variant.architecture).join(", ");
  console.log(`\nPASS LINT-19: SwiftPM selected and executed CogLint for ${hosts}`);
}

/** Selects a build or downloaded-archive proof and its concrete host variants. */
function parseOptions(arguments_) {
  let fromArchive = false;
  const architectures = [];

  for (let index = 0; index < arguments_.length; index += 1) {
    const argument = arguments_[index];
    if (argument === "--from-archive") {
      fromArchive = true;
      continue;
    }
    if (argument === "--host") {
      const architecture = arguments_[index + 1];
      if (architecture === undefined) fail("--host requires an architecture");
      architectures.push(architecture);
      index += 1;
      continue;
    }
    fail(`unrecognized argument ${JSON.stringify(argument)}`);
  }

  const selected =
    architectures.length === 0 ? VARIANTS : architectures.map(variantForArchitecture);
  if (new Set(selected).size !== selected.length) fail("each --host architecture must be unique");
  return { fromArchive, variants: selected };
}

/** Resolves a CLI host name to the one accepted metadata variant. */
function variantForArchitecture(architecture) {
  const variant = VARIANTS.find((candidate) => candidate.architecture === architecture);
  if (variant === undefined)
    fail(`unsupported --host architecture ${JSON.stringify(architecture)}`);
  return variant;
}

/** Requires the exact artifact schema, version, paths, and normalized triples. */
function validateMetadata() {
  const metadata = JSON.parse(readFileSync(join(BUNDLE_PATH, "info.json"), "utf8"));
  const expected = {
    schemaVersion: "1.0",
    artifacts: {
      coglint: {
        type: "executable",
        version: VERSION,
        variants: VARIANTS.map((variant) => ({
          path: variant.relativePath,
          supportedTriples: [variant.supportedTriple],
        })),
      },
    },
  };
  if (JSON.stringify(metadata) !== JSON.stringify(expected)) {
    fail(
      `artifact metadata differs from the accepted contract:\n${JSON.stringify(metadata, null, 2)}`,
    );
  }

  for (const variant of VARIANTS) {
    const executable = join(BUNDLE_PATH, variant.relativePath);
    const architectures = run("lipo", ["-archs", executable], { encoding: "utf8" }).stdout.trim();
    if (architectures !== variant.architecture) {
      fail(`${variant.relativePath} contains ${architectures}, expected ${variant.architecture}`);
    }
  }
}

/** Proves the release archive is one bundle and its recorded checksum is live. */
function validateArchiveAndChecksum() {
  const entries = run("unzip", ["-Z1", ARCHIVE_PATH], { encoding: "utf8" })
    .stdout.trim()
    .split("\n")
    .filter(Boolean);
  if (
    entries.length === 0 ||
    entries.some((entry) => !entry.startsWith(`${BUNDLE_NAME}/`)) ||
    !entries.includes(`${BUNDLE_NAME}/info.json`) ||
    VARIANTS.some((variant) => !entries.includes(`${BUNDLE_NAME}/${variant.relativePath}`))
  ) {
    fail("archive must contain exactly one top-level bundle with its metadata and both tools");
  }

  const recorded = readFileSync(CHECKSUM_PATH, "utf8").trim();
  const computed = run("swift", ["package", "compute-checksum", ARCHIVE_PATH], {
    encoding: "utf8",
  }).stdout.trim();
  if (!/^[0-9a-f]{64}$/.test(recorded) || recorded !== computed) {
    fail(`recorded checksum ${JSON.stringify(recorded)} does not match SwiftPM ${computed}`);
  }
}

/** Extracts the already-checksummed release archive as the sole probe input. */
function materializeBundleFromArchive() {
  rmSync(BUNDLE_PATH, { force: true, recursive: true });
  run("unzip", ["-q", ARCHIVE_PATH, "-d", ARTIFACTS_DIRECTORY]);
  process.on("exit", () => rmSync(BUNDLE_PATH, { force: true, recursive: true }));
}

/** Creates a real binary-target consumer whose command plugin executes its tool. */
function writeProbePackage(directory) {
  cpSync(BUNDLE_PATH, join(directory, BUNDLE_NAME), { recursive: true });
  const pluginDirectory = join(directory, "Plugins", "SelectionProbe");
  mkdirSync(pluginDirectory, { recursive: true });
  writeFileSync(
    join(directory, "Package.swift"),
    `// swift-tools-version:6.2

import PackageDescription

let package = Package(
  name: "CogLintArtifactSelectionProbe",
  platforms: [.macOS(.v14)],
  targets: [
    .binaryTarget(name: "CogLintBinary", path: "${BUNDLE_NAME}"),
    .plugin(
      name: "SelectionProbe",
      capability: .command(
        intent: .custom(
          verb: "probe-coglint-selection",
          description: "Execute the CogLint binary selected for this host"
        )
      ),
      dependencies: ["CogLintBinary"]
    ),
  ]
)
`,
  );
  writeFileSync(
    join(pluginDirectory, "plugin.swift"),
    `import Foundation
import PackagePlugin

@main
struct SelectionProbe: CommandPlugin {
  func performCommand(context: PluginContext, arguments: [String]) async throws {
    let tool = try context.tool(named: "coglint")
    print("coglint-selection-path=\\(tool.url.path)")

    let process = Process()
    process.executableURL = tool.url
    process.arguments = ["--help"]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw SelectionFailure.exitStatus(process.terminationStatus)
    }
  }
}

enum SelectionFailure: Error {
  case exitStatus(Int32)
}
`,
  );
}

/** Runs SwiftPM in one host mode and requires its exact variant and real CLI. */
function validateHostSelection(probeDirectory, swiftExecutable, variant) {
  console.log(`\n==> Probing SwiftPM selection for ${variant.supportedTriple}`);
  const result = run(
    "arch",
    [
      `-${variant.architecture}`,
      swiftExecutable,
      "package",
      "--package-path",
      probeDirectory,
      "--scratch-path",
      join(probeDirectory, `.build-${variant.architecture}`),
      "probe-coglint-selection",
    ],
    { encoding: "utf8" },
  );
  const output = `${result.stdout}\n${result.stderr}`;
  process.stdout.write(output);
  if (!output.includes(`coglint-selection-path=`) || !output.includes(variant.relativePath)) {
    fail(`SwiftPM did not select ${variant.relativePath} for ${variant.supportedTriple}`);
  }
  if (!output.includes("USAGE: coglint")) {
    fail(`the selected ${variant.supportedTriple} executable did not run its CLI`);
  }
}

/** Runs one required subprocess and retains captured output for exact assertions. */
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
    if (options.encoding !== undefined) {
      process.stdout.write(result.stdout ?? "");
      process.stderr.write(result.stderr ?? "");
    }
    fail(`${command} exited with status ${result.status}`);
  }
  return result;
}

/** Reports a suite failure without reducing LINT-19 to a skipped host. */
function fail(message) {
  console.error(`error: coglint artifact test: ${message}`);
  process.exit(1);
}
