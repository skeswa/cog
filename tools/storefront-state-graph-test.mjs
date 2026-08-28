#!/usr/bin/env node

// Runs the separate swift-state-graph Storefront runtime package's tests with
// the guards SwiftPM does not provide itself;
// `lib/guarded-package-test.mjs` implements the guarantee.
//
// The guards apply with more force here: this suite's whole job is to prove
// that a port onto somebody else's library produces the same shopping session
// Cog does. A silently empty run would report agreement that was never
// checked, and a comparison benchmark that quietly measured an unverified
// port is worse than no comparison at all.
//
// Usage: `storefront-state-graph-test.mjs [swift test arguments...]`

import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { runGuardedPackageTests } from "./lib/guarded-package-test.mjs";

/** The repository root, resolved from this file so cwd never matters. */
const REPO_ROOT = fileURLToPath(new URL("..", import.meta.url));

runGuardedPackageTests(
  {
    packagePath: join(REPO_ROOT, "swift", "Benchmarks", "Storefront", "Runtimes", "StateGraph"),
    subject: "cog-storefront-state-graph",
    // A scratch path of its own, under the repository's ignored `.build`, and
    // here that matters twice over: this package resolves the neutral workload
    // by path and swift-state-graph plus its macro toolchain from the network.
    // Sharing a scratch directory with any other package's test builds would
    // make each invalidate the other and would drag a macro toolchain rebuild
    // into unrelated runs.
    scratchPath: join(REPO_ROOT, ".build", "storefront-state-graph"),
  },
  process.argv.slice(2),
);
