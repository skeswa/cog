#!/usr/bin/env node

// Runs the dependency-free Storefront workload package's tests with the guards
// SwiftPM does not provide itself; `lib/guarded-package-test.mjs` implements
// the guarantee.
//
// This package matters more than most: its suite is the correctness gate every
// Storefront benchmark number rests on. A benchmark cut calls
// `requireCheckpointsHold()` before it reports, so a workload that computed the
// wrong answer traps instead of producing a timing — but only these tests say
// *which* claim broke, and only they run the trace under a debugger-friendly
// build.
//
// Usage: `storefront-test.mjs [swift test arguments...]`

import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { runGuardedPackageTests } from "./lib/guarded-package-test.mjs";

/** The repository root, resolved from this file so cwd never matters. */
const REPO_ROOT = fileURLToPath(new URL("..", import.meta.url));

runGuardedPackageTests(
  {
    packagePath: join(REPO_ROOT, "swift", "Benchmarks", "Storefront", "Workload"),
    // The package name rather than the test target name, leaving room for the
    // neutral package to grow more than one test target without making
    // diagnostics misleading.
    subject: "cog-storefront-workload",
    // A scratch path of its own, under the repository's ignored `.build`.
    // Shared with nothing so the neutral workload's compilation state cannot
    // be invalidated by a runtime package that consumes it under different
    // products.
    scratchPath: join(REPO_ROOT, ".build", "storefront"),
  },
  process.argv.slice(2),
);
