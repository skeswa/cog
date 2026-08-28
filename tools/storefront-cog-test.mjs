#!/usr/bin/env node

// Runs the Cog Storefront runtime package's tests with the same
// nonempty-filter and authoritative executed-count guards as every other
// Swift package suite; `lib/guarded-package-test.mjs` implements them.
//
// Usage: `storefront-cog-test.mjs [swift test arguments...]`

import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { runGuardedPackageTests } from "./lib/guarded-package-test.mjs";

/** The repository root, resolved from this file so cwd never matters. */
const REPO_ROOT = fileURLToPath(new URL("..", import.meta.url));

runGuardedPackageTests(
  {
    packagePath: join(REPO_ROOT, "swift", "Benchmarks", "Storefront", "Runtimes", "CogRuntime"),
    subject: "cog-storefront",
    // A scratch path isolated from the workload and other runtime packages.
    scratchPath: join(REPO_ROOT, ".build", "storefront-cog"),
  },
  process.argv.slice(2),
);
