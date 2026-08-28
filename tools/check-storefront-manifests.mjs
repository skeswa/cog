#!/usr/bin/env node

// Proves build-shape parity across the four packages the Storefront
// comparison is compiled in.
//
// The workload is one script run by four runtimes, but those runtimes are
// spread over four SwiftPM packages — the dependency-free workload, the Cog
// port, the two `@Observable` ports, and the swift-state-graph port. Each
// package carries its own copy of the compiler settings every target is built
// with, and SwiftPM manifests cannot import one another, so this check makes
// the copies agree. The agreement is not cosmetic: a comparison whose
// runtimes were compiled under different isolation defaults, language modes,
// or upcoming features would be measuring the settings rather than the
// runtimes.
//
// The settings blocks are compared as *text*, byte for byte, rather than as a
// parsed set: reordering, respelling, or commenting a setting differently in
// one package is exactly the kind of divergence that would otherwise be
// argued away as equivalent. The Verification package is deliberately
// excluded — it is test-only and compiles no runtime under measurement, so it
// declares no `storefrontSwiftSettings` of its own.
//
// This used to be a Swift test inside the Verification package, which meant
// the two assertions only ran after a four-runtime build. Their actual
// dependency is four text files, so they live here and gate that build
// instead.

import { readFileSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

/** The repository root, resolved from this file so cwd never matters. */
const REPO_ROOT = fileURLToPath(new URL("..", import.meta.url));

/** The Storefront suite directory that holds every compared package. */
const STOREFRONT = join(REPO_ROOT, "swift", "Benchmarks", "Storefront");

/**
 * Relative package paths whose settings must agree.
 *
 * The neutral workload comes first: it defines the protocol dialect every
 * runtime implements, so its copy is the reference the others are held to.
 */
const COMPARED_PACKAGES = [
  "Workload",
  "Runtimes/CogRuntime",
  "Runtimes/Observation",
  "Runtimes/StateGraph",
];

main();

/** Runs both parity assertions over the four Storefront manifests. */
function main() {
  const manifests = COMPARED_PACKAGES.map((packagePath) => ({
    packagePath,
    text: manifestText(packagePath),
  }));

  assertSettingsBlocksAreByteIdentical(manifests);
  assertEveryTargetUsesTheSharedSettings(manifests);
  console.log(
    `check-storefront-manifests: ${manifests.length} Storefront manifests share one settings block`,
  );
}

/** Reads one package's manifest, failing loudly when it is missing. */
function manifestText(packagePath) {
  const path = join(STOREFRONT, packagePath, "Package.swift");
  try {
    return readFileSync(path, "utf8");
  } catch (error) {
    fail(`Storefront/${packagePath}/Package.swift is unreadable: ${error.message}`);
  }
}

/**
 * Extracts the `storefrontSwiftSettings` array literal from a manifest.
 *
 * Deliberately narrow: the declaration line and every line through the first
 * closing bracket at column zero, which is precisely the array a
 * `swift format`-ed manifest produces. A second declaration or a missing one
 * both fail, because either means the thing being compared is no longer the
 * thing every target is built with.
 */
function settingsBlock(manifest, packagePath) {
  const lines = manifest.split("\n");
  const declarations = lines
    .map((line, index) => ({ line, index }))
    .filter(({ line }) => line.startsWith("let storefrontSwiftSettings"));
  if (declarations.length !== 1) {
    fail(
      `Storefront/${packagePath}/Package.swift declares no single ` +
        "storefrontSwiftSettings block",
    );
  }
  const start = declarations[0].index;
  const end = lines.findIndex((line, index) => index >= start && line === "]");
  if (end === -1) {
    fail(
      `Storefront/${packagePath}/Package.swift never closes its ` +
        "storefrontSwiftSettings block at column zero",
    );
  }
  return lines.slice(start, end + 1).join("\n");
}

/** All four settings blocks must match the neutral workload's, byte for byte. */
function assertSettingsBlocksAreByteIdentical(manifests) {
  const blocks = manifests.map(({ packagePath, text }) => ({
    packagePath,
    block: settingsBlock(text, packagePath),
  }));
  const reference = blocks[0];
  for (const candidate of blocks.slice(1)) {
    if (candidate.block === reference.block) continue;
    fail(
      `Storefront/${candidate.packagePath}/Package.swift compiles its targets ` +
        `differently from Storefront/${reference.packagePath}/Package.swift, so a ` +
        "comparison between them would measure the settings rather than the " +
        `runtimes.\n\n${reference.packagePath}:\n${reference.block}\n\n` +
        `${candidate.packagePath}:\n${candidate.block}`,
    );
  }
}

/**
 * The block being compared is the one every target actually uses.
 *
 * Parity between four copies of a constant proves nothing if a target has
 * stopped passing that constant to the compiler, so each manifest must
 * reference `storefrontSwiftSettings` at every `swiftSettings:` site it has.
 * A target given its own inline settings array raises the `swiftSettings:`
 * count without raising the reference count, which is the case this catches.
 */
function assertEveryTargetUsesTheSharedSettings(manifests) {
  for (const { packagePath, text } of manifests) {
    const lines = text.split("\n");
    const uses = lines.filter((line) =>
      line.includes("swiftSettings: storefrontSwiftSettings"),
    ).length;
    const settingsSites = lines.filter((line) => line.includes("swiftSettings:")).length;
    if (uses === 0) {
      fail(`Storefront/${packagePath}/Package.swift builds no target with the shared settings`);
    }
    if (uses !== settingsSites) {
      fail(
        `Storefront/${packagePath}/Package.swift has ${settingsSites - uses} target(s) with ` +
          "settings of their own, which the parity check would not see.",
      );
    }
  }
}

/** Reports a check failure and exits nonzero. */
function fail(message) {
  console.error(`error: check-storefront-manifests: ${message}`);
  process.exit(1);
}
