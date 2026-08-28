#!/usr/bin/env node

// Runs the separate plain-Swift Storefront comparison-runtime package's tests
// with the guards SwiftPM does not provide itself;
// `lib/guarded-package-test.mjs` implements the guarantee.
//
// The guards apply with more force here: this suite's whole job is to prove
// that two runtimes with no Cog in them produce the same shopping session Cog
// does. A silently empty run would report agreement that was never checked,
// and the benchmark numbers this package eventually publishes rest entirely
// on that agreement.
//
// Usage: `storefront-runtimes-test.mjs [swift test arguments...]`

import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { runGuardedPackageTests } from "./lib/guarded-package-test.mjs";

/** The repository root, resolved from this file so cwd never matters. */
const REPO_ROOT = fileURLToPath(new URL("..", import.meta.url));

runGuardedPackageTests(
  {
    packagePath: join(REPO_ROOT, "swift", "Benchmarks", "Storefront", "Runtimes", "Observation"),
    // The package name rather than a target name: `cog-storefront-observation`
    // builds one test target today but two library targets —
    // `StorefrontObservationRaw` and `StorefrontObservationMemo` — and the
    // guards speak for the whole package. A literal one-target name here would
    // name part of the run in a message about all of it, which is exactly the
    // kind of misdirection a guard exists to avoid.
    subject: "cog-storefront-observation",
    // A scratch path of its own, under the repository's ignored `.build`.
    // Shared with nothing: a scratch directory of its own keeps runtime builds
    // from invalidating one another even though they consume the same workload
    // product.
    scratchPath: join(REPO_ROOT, ".build", "storefront-runtimes"),
  },
  process.argv.slice(2),
);
