// The one description of the CogLint artifact and its distribution shape.
//
// The pipeline around `CogLintBinary.artifactbundle` spans six tools — the
// artifact builder, the Channel B generator, and four integration tests that
// each stand up a scratch SwiftPM consumer. Before this module, every one of
// them carried its own copy of the bundle names, the artifact paths, the
// variant table, the consumer-manifest text, the rebuild-if-stale logic, and
// a process runner. The copies drifted in shape (three spellings of the
// variant table) and nothing compared the user-visible `verb`/`description`
// strings between the shipped manifest and the tested one.
//
// This module is the single home: the generator and every scratch consumer
// build their manifest text through `consumerManifest`, so a test cannot pass
// against a manifest shape that is not the shipped one. Deliberate
// redundancies stay outside it — `test-coglint-documentation.mjs`'s RULES
// table is an independent oracle, and `test-coglint-artifact.mjs` still
// spells the artifact-metadata schema itself so the builder cannot drift in
// step with its own test.

import { existsSync, readdirSync, statSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

/** The repository root, resolved from this file so cwd never matters. */
const REPO_ROOT = fileURLToPath(new URL("../..", import.meta.url));

/** The isolated source package that owns every CogLint distribution input. */
export const LINT_PACKAGE = join(REPO_ROOT, "swift", "Lint");

/** Generated artifacts stay beside their isolated development package. */
export const ARTIFACTS_DIRECTORY = join(LINT_PACKAGE, "Artifacts");

/** The exact bundle and release-asset names accepted by lint.md section 7. */
export const BUNDLE_NAME = "CogLintBinary.artifactbundle";
export const ARCHIVE_NAME = `${BUNDLE_NAME}.zip`;

/** The generated bundle, archive, and checksum the builder owns. */
export const BUNDLE_PATH = join(ARTIFACTS_DIRECTORY, BUNDLE_NAME);
export const ARCHIVE_PATH = `${BUNDLE_PATH}.zip`;
export const CHECKSUM_PATH = `${ARCHIVE_PATH}.checksum`;

/** The generated Channel B package identity. */
export const PLUGINS_PACKAGE_NAME = "CogLintPlugins";

/** Accepts one release version, including prerelease and build metadata. */
export const SEMANTIC_VERSION = /^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$/;

/**
 * Native variants accepted for a CogLint release.
 *
 * One table serves the builder (build triples and bundle directories), the
 * artifact test (selection triples and contained paths), and the command
 * plugin test (the host binary's path inside a consumed bundle).
 */
export const VARIANTS = [
  {
    architecture: "arm64",
    buildTriple: "arm64-apple-macosx14.0",
    supportedTriple: "arm64-apple-macosx",
    directory: "coglint-arm64-apple-macosx",
    relativePath: "coglint-arm64-apple-macosx/bin/coglint",
  },
  {
    architecture: "x86_64",
    buildTriple: "x86_64-apple-macosx14.0",
    supportedTriple: "x86_64-apple-macosx",
    directory: "coglint-x86_64-apple-macosx",
    relativePath: "coglint-x86_64-apple-macosx/bin/coglint",
  },
];

/**
 * The two shipped plugin descriptors, exactly as Channel B publishes them.
 *
 * The `verb` and `description` here are user-visible interface strings. Every
 * scratch consumer that applies a CogLint plugin builds its manifest from
 * these same descriptors, which is what makes drift between the shipped and
 * tested spellings impossible.
 */
export const BUILD_TOOL_PLUGIN = { name: "CogLintBuildToolPlugin", buildTool: true };
export const COMMAND_PLUGIN = {
  name: "CogLintCommandPlugin",
  command: {
    verb: "coglint",
    description: "Check Swift sources against Cog conventions",
    permissions: true,
  },
};
export const COGLINT_PLUGINS = [BUILD_TOOL_PLUGIN, COMMAND_PLUGIN];

/** The accepted release-asset URL for one version. */
export function releaseArtifactURL(version) {
  return `https://github.com/skeswa/cog/releases/download/${version}/${ARCHIVE_NAME}`;
}

/** The checked-in source directory of one plugin. */
export function pluginSourceDirectory(name) {
  return join(LINT_PACKAGE, "Plugins", name);
}

/** The checked-in `plugin.swift` of one plugin. */
export function pluginSourcePath(name) {
  return join(pluginSourceDirectory(name), "plugin.swift");
}

/**
 * Produces one CogLint consumer manifest.
 *
 * The generator emits the shipping Channel B manifest through this function,
 * and the integration tests emit their scratch consumers through it too, so
 * the only differences a test can introduce are the ones this signature
 * names: the package identity, a local bundle path instead of a released
 * URL-plus-checksum, which plugins are declared, and whether they are
 * exported as products.
 *
 * @param {object} shape
 * @param {string} shape.name Package name.
 * @param {string} [shape.marker] Generated-file marker comment, shipping only.
 * @param {{path: string} | {url: string, checksum: string}} shape.binaryTarget
 *   A local bundle path (scratch consumers) or a release URL and checksum
 *   (the shipped manifest).
 * @param {Array<{name: string, buildTool?: boolean, command?: {verb: string,
 *   description: string, permissions?: boolean}}>} shape.plugins Plugin
 *   descriptors, normally drawn from the shipped constants above.
 * @param {boolean} [shape.products] Whether each plugin is also a product.
 */
export function consumerManifest({ name, marker, binaryTarget, plugins, products = true }) {
  const header =
    marker === undefined
      ? "// swift-tools-version:6.2\n"
      : `// swift-tools-version:6.2\n// ${marker}\n`;

  const productLines = products
    ? `  products: [\n${plugins
        .map((plugin) => `    .plugin(name: "${plugin.name}", targets: ["${plugin.name}"]),\n`)
        .join("")}  ],\n`
    : "";

  const binaryTargetLines =
    "path" in binaryTarget
      ? `    .binaryTarget(name: "CogLintBinary", path: "${binaryTarget.path}"),\n`
      : `    .binaryTarget(\n` +
        `      name: "CogLintBinary",\n` +
        `      url: ${JSON.stringify(binaryTarget.url)},\n` +
        `      checksum: ${JSON.stringify(binaryTarget.checksum)}\n` +
        `    ),\n`;

  const pluginLines = plugins.map(pluginTarget).join("");

  return (
    `${header}\nimport PackageDescription\n\n` +
    `let package = Package(\n` +
    `  name: "${name}",\n` +
    `  platforms: [.macOS(.v14)],\n` +
    productLines +
    `  targets: [\n` +
    binaryTargetLines +
    pluginLines +
    `  ]\n)\n`
  );
}

/** Emits one `.plugin` target from a descriptor. */
function pluginTarget(plugin) {
  const capability =
    plugin.buildTool === true
      ? "      capability: .buildTool(),\n"
      : `      capability: .command(\n` +
        `        intent: .custom(\n` +
        `          verb: "${plugin.command.verb}",\n` +
        `          description: "${plugin.command.description}"\n` +
        `        )${plugin.command.permissions === true ? ",\n        permissions: []" : ""}\n` +
        `      ),\n`;
  return (
    `    .plugin(\n` +
    `      name: "${plugin.name}",\n` +
    capability +
    `      dependencies: ["CogLintBinary"]\n` +
    `    ),\n`
  );
}

/**
 * Rebuilds the artifact when any distribution input is newer than the archive.
 *
 * The inputs are the lint package's manifest, pins, and sources, the builder
 * itself, and this module, which the builder now depends on.
 *
 * @param {(message: string) => never} fail The caller's reporter.
 */
export function ensureCurrentArtifact(fail) {
  const inputs = [
    join(LINT_PACKAGE, "Package.swift"),
    join(LINT_PACKAGE, "Package.resolved"),
    join(LINT_PACKAGE, "Sources"),
    join(REPO_ROOT, "tools", "build-coglint-artifact.mjs"),
    join(REPO_ROOT, "tools", "lib", "coglint-artifact.mjs"),
  ];
  const latestInput = Math.max(...inputs.map(latestModificationTime));
  if (!existsSync(ARCHIVE_PATH) || statSync(ARCHIVE_PATH).mtimeMs < latestInput) {
    const { runSuccessful } = makeRunners(fail);
    runSuccessful(process.execPath, [join(REPO_ROOT, "tools", "build-coglint-artifact.mjs")], {
      stdio: "inherit",
    });
  } else {
    console.log("==> Reusing the artifact built from the current CogLint sources");
  }
}

/** Finds the newest regular file below one input path. */
function latestModificationTime(path) {
  const status = statSync(path);
  if (!status.isDirectory()) return status.mtimeMs;
  return Math.max(
    status.mtimeMs,
    ...readdirSync(path).map((entry) => latestModificationTime(join(path, entry))),
  );
}

/**
 * Builds this pipeline's two subprocess runners around one failure reporter.
 *
 * Every tool in the pipeline runs subprocesses the same two ways — required
 * to succeed, or captured for its own status assertions — differing only in
 * whose name the failure carries. The factory keeps that name with the
 * caller.
 *
 * @param {(message: string) => never} fail The caller's reporter.
 */
export function makeRunners(fail) {
  /** Runs one command while retaining output for the caller's own checks. */
  function runCaptured(command, arguments_, options = {}) {
    const result = spawnSync(command, arguments_, {
      maxBuffer: 64 * 1024 * 1024,
      ...options,
    });
    if (result.error !== undefined) {
      fail(`could not run ${command}: ${result.error.message}`);
    }
    if (result.signal !== null && result.signal !== undefined) {
      fail(`${command} was killed by ${result.signal}`);
    }
    return result;
  }

  /** Runs one required subprocess, echoing captured output when it fails. */
  function runSuccessful(command, arguments_, options = {}) {
    const result = runCaptured(command, arguments_, options);
    if (result.status !== 0) {
      if (typeof result.stdout === "string") process.stdout.write(result.stdout);
      if (typeof result.stderr === "string") process.stderr.write(result.stderr);
      fail(`${command} exited with status ${result.status}`);
    }
    return result;
  }

  return { runCaptured, runSuccessful };
}
