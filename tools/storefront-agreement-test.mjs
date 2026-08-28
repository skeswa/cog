#!/usr/bin/env node

// Runs the cross-runtime Storefront agreement suite with the guards SwiftPM
// does not provide itself; `lib/guarded-package-test.mjs` implements the
// guarantee.
//
// This is the strongest correctness gate the Storefront macrobenchmark has: it
// links all four runtimes — the Cog port, the raw `@Observable` floor, the
// hand-memoized `@Observable` port, and the swift-state-graph port — and proves
// they computed the *same answers* before any timing between them is allowed to
// mean anything. Without it a fast number might simply be a wrong number.
//
// The suite lives in Storefront's dedicated Verification package. That package
// is the intentional integration point where all four runtimes coexist;
// individual runtime packages still cannot see one another. The guards matter
// more here than anywhere: an empty run would report agreement that was never
// checked.
//
// Usage: `storefront-agreement-test.mjs [swift test arguments...]`

import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { runGuardedPackageTests } from "./lib/guarded-package-test.mjs";

/** The repository root, resolved from this file so cwd never matters. */
const REPO_ROOT = fileURLToPath(new URL("..", import.meta.url));

runGuardedPackageTests(
  {
    packagePath: join(REPO_ROOT, "swift", "Benchmarks", "Storefront", "Verification"),
    // The package name names the one responsibility this package has.
    subject: "cog-storefront-verification",
    // A scratch path of its own, under the repository's ignored `.build`.
    // Shared with nothing, and in particular not with the headless runner. The
    // verification and measurement packages compile the same runtimes for
    // different purposes, so sharing would make each invalidate the other.
    scratchPath: join(REPO_ROOT, ".build", "storefront-agreement"),
  },
  process.argv.slice(2),
);
