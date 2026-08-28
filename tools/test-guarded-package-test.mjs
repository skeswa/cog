#!/usr/bin/env node

// Proves the guarded package-test module refuses the runs SwiftPM would
// silently pass: zero listed tests, a filter or filter alternative that
// selects nothing, a run that executed zero tests, a run that produced no
// xUnit report, and a caller-supplied `--xunit-output`. A fake `swift`
// executable on PATH controls each case, so no Swift build is involved and
// the suite exercises the module through a real entry script, exactly as the
// six package wrappers do.

import { spawnSync } from "node:child_process";
import { chmodSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { delimiter, join } from "node:path";
import { pathToFileURL } from "node:url";

/** The guarded module under test, imported by the scratch entry script. */
const MODULE_URL = pathToFileURL(
  join(new URL(".", import.meta.url).pathname, "lib", "guarded-package-test.mjs"),
).href;

/**
 * A fake `swift` that answers `swift test list` from `FAKE_SWIFT_LIST` and
 * `swift test` from `FAKE_SWIFT_RUN` (`report:<count>` writes an xUnit file at
 * the wrapper's `--xunit-output` path; anything else writes nothing).
 *
 * Written without an `.mjs` extension so PATH resolution finds it as `swift`;
 * Node treats the extensionless file as CommonJS, hence `require`.
 */
const FAKE_SWIFT = `#!/usr/bin/env node
const { writeFileSync } = require("node:fs");
const args = process.argv.slice(2);
if (args[0] === "test" && args[1] === "list") {
  process.stdout.write(process.env.FAKE_SWIFT_LIST ?? "");
  process.exit(0);
}
const behavior = process.env.FAKE_SWIFT_RUN ?? "none";
if (behavior.startsWith("report:")) {
  const tests = behavior.slice("report:".length);
  const report = args[args.indexOf("--xunit-output") + 1];
  writeFileSync(report, \`<testsuite name="fake" tests="\${tests}"></testsuite>\`);
}
process.exit(0);
`;

main();

/** Builds the fixture wrapper once and drives every guard path through it. */
function main() {
  withScratch("guarded-package-test-", (directory) => {
    const binDirectory = join(directory, "bin");
    mkdirSync(binDirectory);
    const fakeSwift = join(binDirectory, "swift");
    writeFileSync(fakeSwift, FAKE_SWIFT);
    chmodSync(fakeSwift, 0o755);

    // A real entry script, so the failure prefix and argument handling are
    // proven the way the six package wrappers exercise them.
    const entry = join(directory, "fixture-package-test.mjs");
    writeFileSync(
      entry,
      `import { runGuardedPackageTests } from ${JSON.stringify(MODULE_URL)};\n` +
        `runGuardedPackageTests(\n` +
        `  {\n` +
        `    packagePath: ${JSON.stringify(directory)},\n` +
        `    subject: "fixture-package",\n` +
        `    scratchPath: ${JSON.stringify(join(directory, "scratch"))},\n` +
        `  },\n` +
        `  process.argv.slice(2),\n` +
        `);\n`,
    );

    const listing = "FixtureTests.first\nFixtureTests.second\n";
    const run = (args, env) =>
      spawnSync(process.execPath, [entry, ...args], {
        encoding: "utf8",
        env: {
          ...process.env,
          PATH: `${binDirectory}${delimiter}${process.env.PATH}`,
          FAKE_SWIFT_LIST: listing,
          FAKE_SWIFT_RUN: "report:2",
          ...env,
        },
      });

    verifyPasses(run);
    verifyRefusals(run);
  });
  console.log("test-guarded-package-test: all guard fixture cases passed");
}

/** A healthy run reports its authoritative executed count and exits zero. */
function verifyPasses(run) {
  const unfiltered = run([], {});
  if (unfiltered.status !== 0) {
    fail(`a healthy unfiltered run failed:\n${unfiltered.stderr}`);
  }
  if (!unfiltered.stdout.includes("fixture-package authoritative executed-test count: 2")) {
    fail("a healthy run did not report its authoritative executed-test count");
  }

  const filtered = run(["--filter", "first|second"], {});
  if (filtered.status !== 0) {
    fail(`a healthy filtered run failed:\n${filtered.stderr}`);
  }
}

/** Each guard refuses its case nonzero, naming the entry script and reason. */
function verifyRefusals(run) {
  const cases = [
    {
      what: "a package listing zero tests",
      result: run([], { FAKE_SWIFT_LIST: "" }),
      expect: "lists zero tests, so the test run was refused",
    },
    {
      what: "a filter selecting no tests",
      result: run(["--filter", "Nonexistent"], {}),
      expect: "filter selected no tests",
    },
    {
      what: "a filter alternative selecting no tests",
      result: run(["--filter", "first|Nonexistent"], {}),
      expect: "selected no tests for the alternative",
    },
    {
      what: "a run that executed zero tests",
      result: run([], { FAKE_SWIFT_RUN: "report:0" }),
      expect: "executed zero tests",
    },
    {
      what: "a run that produced no report",
      result: run([], { FAKE_SWIFT_RUN: "none" }),
      expect: "produced no xUnit report",
    },
    {
      what: "a caller-supplied xUnit destination",
      result: run(["--xunit-output", "elsewhere.xml"], {}),
      expect: "reserved for the wrapper's executed-test count",
    },
  ];

  for (const { what, result, expect } of cases) {
    if (result.status === 0) {
      fail(`${what} unexpectedly passed`);
    }
    if (!result.stderr.includes(expect)) {
      fail(`${what} failed without the expected diagnostic:\n${result.stderr}`);
    }
    if (!result.stderr.includes("error: fixture-package-test:")) {
      fail(`${what} did not name the entry script in its failure:\n${result.stderr}`);
    }
  }
}

function withScratch(prefix, operation) {
  const directory = mkdtempSync(join(tmpdir(), prefix));
  try {
    operation(directory);
  } finally {
    rmSync(directory, { force: true, recursive: true });
  }
}

function fail(message) {
  console.error(`error: test-guarded-package-test: ${message}`);
  process.exit(1);
}
