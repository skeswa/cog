#!/usr/bin/env node

// Runs the separate CogLint package's tests with the guards SwiftPM does not
// provide itself; `lib/guarded-package-test.mjs` implements the guarantee.
//
// Usage: `swift-lint-test.mjs [swift test arguments...]`

import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { runGuardedPackageTests } from "./lib/guarded-package-test.mjs";

/** The repository root, resolved from this file so cwd never matters. */
const REPO_ROOT = fileURLToPath(new URL("..", import.meta.url));

runGuardedPackageTests(
  {
    packagePath: join(REPO_ROOT, "swift", "Lint"),
    subject: "CogLint",
    scratchPath: join(REPO_ROOT, "swift", "Lint", ".build", "tests-debug"),
  },
  process.argv.slice(2),
);
