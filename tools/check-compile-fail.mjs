#!/usr/bin/env node
// Batched compile-fail harness for the Swift package.
//
//     node tools/check-compile-fail.mjs [options]
//
// Every scenario in docs/swift/impl/scenarios.md marked `(Proof: compile-fail.)`
// is proven by a fixture under `swift/CompileFail/`. All fixtures sharing a
// build configuration are type-checked by ONE `swiftc -typecheck` invocation —
// never one compiler run per fixture — and this tool then attributes each
// diagnostic back to the fixture that produced it and matches it against that
// fixture's declared expectations. Fixtures declaring
// `// configuration: release` form a second batched pass against the
// release-built modules; that is how `(Proof: release configuration.)`
// absence claims — API that exists only in debug builds — stay continuously
// verified rather than resting on the test gates that compile the debug-only
// suites away.
//
// ## Fixture contract
//
// A fixture is any `.swift` file under `swift/CompileFail/` (subdirectories are
// allowed and are only for grouping). It is NOT a SwiftPM target: nothing under
// `swift/CompileFail/` appears in `Package.swift`, so `swift build` and
// `swift test` never see it. It IS formatted and linted by `mise run fmt`, so a
// fixture must stay parseable and swift-format-clean; prove *semantic* errors,
// never syntax errors.
//
// Directives are line comments:
//
//   // scenario: DECL-06
//       Required, exactly once. The scenario ID this fixture proves. Must exist
//       in scenarios.md and be marked `(Proof: compile-fail.)` there, unless it
//       uses the reserved `HARNESS-` prefix (fixtures that prove the harness
//       itself rather than a product scenario).
//
//   // expect-error: cannot assign to value
//       At least one required. Asserts that the compiler emits an error on a
//       specific line whose message CONTAINS this substring. A standalone
//       `// expect-error:` comment binds to the next line that is neither blank
//       nor a comment; written as a trailing comment (two spaces before `//`,
//       as swift-format requires) it binds to its own line.
//
//   // expect-error-anywhere: cannot assign to value
//       Same, but satisfied by a matching error anywhere in the fixture. Use it
//       only when the compiler attributes the diagnostic to a line the fixture
//       cannot predict.
//
//   // configuration: release
//       Optional, at most once; the default is `debug`. Type-checks this
//       fixture against the release-built library modules instead of the debug
//       ones. A release fixture's scenario must be marked
//       `(Proof: release configuration.)` in scenarios.md, the way a debug
//       fixture's must be marked `(Proof: compile-fail.)`.
//
// Both directions are enforced. A fixture that emits no error at all fails
// (`no-diagnostic`) — a compile-fail test that quietly starts compiling proves
// nothing. An expectation with no matching error fails (`missing-diagnostic`),
// and an error no expectation covers fails (`unexpected-diagnostic`).
//
// ## Naming
//
// All fixtures are type-checked as one module (`CogCompileFail`), which is what
// makes the single batched pass possible. Top-level declaration names must
// therefore be unique across the whole fixture set: nest a fixture's
// declarations in one namespace `enum` named after its file. A collision shows
// up as an uncovered `invalid redeclaration` error, so it fails loudly rather
// than silently satisfying the wrong expectation.
//
// ## Compiler flags
//
// The fixture flags are DERIVED FROM `Package.swift` — `librarySettings` and
// the `.macOS` platform — so they cannot drift from the library. A setting this
// tool does not know how to translate is a hard error (`unknown-setting`)
// rather than a silent omission, so adding one to the manifest forces a
// matching change here.
//
// ## Options
//
//   --filter <regex>   Only fixtures whose scenario ID or repo-relative path
//                      matches. Fails if the expression selects nothing.
//   --list             Print the fixture inventory and exit; compile nothing.
//   --no-build         Skip `swift build` (the modules must already exist).
//   --no-check-scenarios  Skip the scenarios.md cross-check.
//   --scratch-path <p>  SwiftPM scratch path. Default `.build/compilefail`.
//   --json             Machine-readable report on stdout.
//   -h, --help
//
// Exits 0 when every fixture fails exactly as declared, 1 on any check
// failure, and 2 on a usage or harness error.

import { spawnSync } from "node:child_process";
import { existsSync, readFileSync, readdirSync, statSync } from "node:fs";
import { join, relative, resolve } from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";
import { shippingManifestEnvironment } from "./lib/cog-environment.mjs";

const REPO_ROOT = resolve(fileURLToPath(new URL("..", import.meta.url)));
const FIXTURE_ROOT = resolve(REPO_ROOT, "swift/CompileFail");
const SCENARIOS = resolve(REPO_ROOT, "docs/swift/impl/scenarios.md");
const DEFAULT_SCRATCH = resolve(REPO_ROOT, ".build/compilefail");

/** Module name for the single batched type-check invocation. */
const MODULE_NAME = "CogCompileFail";

/** Scenario-ID prefix reserved for fixtures that prove the harness itself. */
const HARNESS_PREFIX = "HARNESS-";

const USAGE =
  "usage: node tools/check-compile-fail.mjs [--filter <regex>] [--list] " +
  "[--no-build] [--no-check-scenarios] [--scratch-path <path>] [--json]\n";

// MARK: - Small helpers

/** @param {string} message */
function fail(message) {
  process.stderr.write(`check-compile-fail: ${message}\n`);
  process.exit(2);
}

/** @param {string} path */
function repoPath(path) {
  return relative(REPO_ROOT, path) || path;
}

/**
 * Normalizes the typographic quotes some diagnostics use so that expectation
 * substrings can be typed with plain ASCII quotes.
 *
 * @param {string} text
 */
function normalize(text) {
  return text.replace(/[‘’]/g, "'").replace(/[“”]/g, '"');
}

// MARK: - Arguments

/** @param {string[]} argv */
function parseArgs(argv) {
  const options = {
    /** @type {RegExp | null} */ filter: null,
    /** @type {string | null} */ filterSource: null,
    json: false,
    build: true,
    checkScenarios: true,
    list: false,
    scratchPath: DEFAULT_SCRATCH,
  };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    /** @param {string} name */
    const value = (name) => {
      index += 1;
      if (index >= argv.length) fail(`${name} requires a value`);
      return argv[index];
    };
    switch (arg) {
      case "--help":
      case "-h":
        process.stdout.write(USAGE);
        process.exit(0);
      // falls through — unreachable, `exit` above.
      case "--json":
        options.json = true;
        break;
      case "--list":
        options.list = true;
        break;
      case "--no-build":
        options.build = false;
        break;
      case "--no-check-scenarios":
        options.checkScenarios = false;
        break;
      case "--scratch-path":
        options.scratchPath = resolve(value("--scratch-path"));
        break;
      case "--filter": {
        const pattern = value("--filter");
        options.filterSource = pattern;
        try {
          options.filter = new RegExp(pattern);
        } catch (error) {
          fail(`--filter is not a valid regular expression: ${error.message}`);
        }
        break;
      }
      default:
        fail(`unknown option ${arg}\n${USAGE}`);
    }
  }
  return options;
}

// MARK: - Package.swift → compiler flags

/**
 * Resolves Package.swift without traits or ambient selectors and translates
 * Cog's resulting settings into the direct `swiftc` fixture invocation.
 *
 * SwiftPM, rather than a source-text append scan, chooses conditional branches.
 * That guarantees fixtures model the specialized pool-edge shipping default.
 * Deliberately strict: an unfamiliar resolved setting aborts the run.
 */
function compilerSettingsFromManifest() {
  const environment = shippingManifestEnvironment(process.env);
  const dumped = spawnSync("swift", ["package", "dump-package", "--disable-default-traits"], {
    cwd: REPO_ROOT,
    encoding: "utf8",
    env: environment,
    maxBuffer: 8 * 1024 * 1024,
  });
  if (dumped.error) fail(`cannot run \`swift package dump-package\`: ${dumped.error.message}`);
  if (dumped.status !== 0) {
    process.stderr.write(dumped.stderr ?? "");
    fail("`swift package dump-package` failed while resolving shipping fixture settings");
  }

  const manifest = JSON.parse(dumped.stdout);
  const cog = manifest.targets?.find((target) => target.name === "Cog");
  if (cog === undefined) fail("the resolved package no longer contains the Cog target");

  /** @type {string[]} */
  const flags = [];
  for (const setting of cog.settings ?? []) {
    if ((setting.condition?.traits?.length ?? 0) > 0) continue;
    const entries = Object.entries(setting.kind ?? {});
    if (setting.tool !== "swift" || entries.length !== 1) {
      fail(`unknown-setting: unresolved Cog setting ${JSON.stringify(setting)}`);
    }
    const [kind, payload] = entries[0];
    const value = payload?._0;
    switch (kind) {
      case "swiftLanguageMode":
        flags.push("-swift-version", value);
        break;
      case "defaultIsolation":
        flags.push("-default-isolation", value ?? "nonisolated");
        break;
      case "enableUpcomingFeature":
        flags.push("-enable-upcoming-feature", value);
        break;
      case "enableExperimentalFeature":
        flags.push("-enable-experimental-feature", value);
        break;
      case "define":
        flags.push(`-D${value}`);
        break;
      case "unsafeFlags":
        flags.push(...(Array.isArray(value) ? value : [value]));
        break;
      default:
        fail(`unknown-setting: resolved Cog setting ${JSON.stringify(setting)}`);
    }
  }

  const macOS = manifest.platforms?.find((platform) => platform.platformName === "macos");
  if (macOS === undefined) fail("Package.swift no longer declares a macOS platform");
  const arch = process.arch === "arm64" ? "arm64" : "x86_64";

  return { flags, target: `${arch}-apple-macosx${macOS.version}` };
}

// MARK: - Fixture discovery and parsing

/** @param {string} directory */
function swiftFilesUnder(directory) {
  /** @type {string[]} */
  const files = [];
  for (const entry of readdirSync(directory, { withFileTypes: true })) {
    if (entry.name.startsWith(".")) continue;
    const path = join(directory, entry.name);
    if (entry.isDirectory()) files.push(...swiftFilesUnder(path));
    else if (entry.isFile() && entry.name.endsWith(".swift")) files.push(path);
  }
  return files.sort();
}

const DIRECTIVE =
  /^\/\/\s*(scenario|expect-error|expect-error-anywhere|configuration)\s*:\s*(.+?)\s*$/;
const TRAILING_DIRECTIVE = /\S\s{2,}\/\/\s*(expect-error|expect-error-anywhere)\s*:\s*(.+?)\s*$/;

/**
 * @param {string} path
 * @returns {{
 *   path: string,
 *   relativePath: string,
 *   scenario: string | null,
 *   configuration: string,
 *   expectations: Array<{ text: string, line: number, anywhere: boolean, directiveLine: number }>,
 *   diagnostics: Array<{ check: string, line: number, message: string }>,
 * }}
 */
function parseFixture(path) {
  const relativePath = repoPath(path);
  const lines = readFileSync(path, "utf8").split("\n");
  /** @type {string | null} */
  let scenario = null;
  /** @type {string | null} */
  let configuration = null;
  /** @type {Array<{ text: string, line: number, anywhere: boolean, directiveLine: number }>} */
  const expectations = [];
  /** @type {Array<{ check: string, line: number, message: string }>} */
  const diagnostics = [];

  /** The next line that is neither blank nor a comment, 1-based; 0 when none. */
  const nextCodeLine = (fromIndex) => {
    for (let index = fromIndex + 1; index < lines.length; index += 1) {
      const trimmed = lines[index].trim();
      if (trimmed.length === 0 || trimmed.startsWith("//")) continue;
      return index + 1;
    }
    return 0;
  };

  for (let index = 0; index < lines.length; index += 1) {
    const line = lines[index];
    const lineNumber = index + 1;
    const trimmed = line.trim();

    if (trimmed.startsWith("//")) {
      const match = DIRECTIVE.exec(trimmed);
      if (match === null) continue;
      const [, kind, text] = match;
      if (kind === "scenario") {
        if (scenario !== null) {
          diagnostics.push({
            check: "duplicate-scenario",
            line: lineNumber,
            message: `a fixture declares one \`// scenario:\` directive; already saw \`${scenario}\``,
          });
          continue;
        }
        if (!/^[A-Z][A-Z0-9]*-\d+[a-z]?$/.test(text)) {
          diagnostics.push({
            check: "malformed-scenario",
            line: lineNumber,
            message: `\`${text}\` is not a scenario ID (expected e.g. \`DECL-06\`)`,
          });
          continue;
        }
        scenario = text;
        continue;
      }
      if (kind === "configuration") {
        if (configuration !== null) {
          diagnostics.push({
            check: "duplicate-configuration",
            line: lineNumber,
            message:
              "a fixture declares at most one `// configuration:` directive; " +
              `already saw \`${configuration}\``,
          });
          continue;
        }
        if (text !== "debug" && text !== "release") {
          diagnostics.push({
            check: "malformed-configuration",
            line: lineNumber,
            message: `\`${text}\` is not a fixture configuration (expected \`debug\` or \`release\`)`,
          });
          continue;
        }
        configuration = text;
        continue;
      }
      const anywhere = kind === "expect-error-anywhere";
      const boundLine = anywhere ? 0 : nextCodeLine(index);
      if (!anywhere && boundLine === 0) {
        diagnostics.push({
          check: "dangling-expectation",
          line: lineNumber,
          message:
            "`// expect-error:` has no following source line to bind to; " +
            "move it above the offending line or use `// expect-error-anywhere:`",
        });
        continue;
      }
      expectations.push({ text, line: boundLine, anywhere, directiveLine: lineNumber });
      continue;
    }

    const trailing = TRAILING_DIRECTIVE.exec(line);
    if (trailing !== null) {
      const [, kind, text] = trailing;
      const anywhere = kind === "expect-error-anywhere";
      expectations.push({
        text,
        line: anywhere ? 0 : lineNumber,
        anywhere,
        directiveLine: lineNumber,
      });
    }
  }

  if (scenario === null) {
    diagnostics.push({
      check: "missing-scenario",
      line: 1,
      message: "fixture has no `// scenario: <ID>` directive",
    });
  }
  if (expectations.length === 0) {
    diagnostics.push({
      check: "no-expectations",
      line: 1,
      message: "fixture declares no `// expect-error:` directive, so it asserts nothing",
    });
  }

  return {
    path,
    relativePath,
    scenario,
    configuration: configuration ?? "debug",
    expectations,
    diagnostics,
  };
}

// MARK: - scenarios.md cross-check

/**
 * Maps every scenario ID in scenarios.md to whether it is declared
 * `(Proof: compile-fail.)` and whether it is declared
 * `(Proof: release configuration.)`. Returns null when the ledger is
 * unreadable, which downgrades the cross-check to a no-op rather than a
 * failure.
 */
function readScenarioProofModes() {
  if (!existsSync(SCENARIOS)) return null;
  let source;
  try {
    source = readFileSync(SCENARIOS, "utf8");
  } catch {
    return null;
  }
  /** @type {Map<string, { compileFail: boolean, releaseConfiguration: boolean }>} */
  const modes = new Map();
  const pattern = /^-\s+\*\*([A-Z][A-Z0-9]*-\d+[a-z]?)\.\*\*/gm;
  /** @type {RegExpExecArray | null} */
  let match;
  const starts = [];
  while ((match = pattern.exec(source)) !== null) {
    starts.push({ id: match[1], index: match.index });
  }
  for (let index = 0; index < starts.length; index += 1) {
    const end = index + 1 < starts.length ? starts[index + 1].index : source.length;
    const body = source.slice(starts[index].index, end);
    modes.set(starts[index].id, {
      compileFail: /\(Proof:\s*compile-fail\.?\)/.test(body),
      releaseConfiguration: /\(Proof:\s*release configuration\.?\)/.test(body),
    });
  }
  return modes.size === 0 ? null : modes;
}

// MARK: - Diagnostic parsing

const LOCATED = /^(.*?):(\d+):(\d+):\s+(error|warning|note|remark):\s+(.*)$/;
const UNLOCATED = /^(?:<unknown>:0:\s+)?(error|warning):\s+(.*)$/;

/** @param {string} output */
function parseDiagnostics(output) {
  /** @type {Array<{ path: string | null, line: number, column: number, severity: string, message: string }>} */
  const diagnostics = [];
  for (const line of output.split("\n")) {
    const located = LOCATED.exec(line);
    if (located !== null) {
      diagnostics.push({
        path: resolve(located[1]),
        line: Number(located[2]),
        column: Number(located[3]),
        severity: located[4],
        message: normalize(located[5]),
      });
      continue;
    }
    const unlocated = UNLOCATED.exec(line);
    if (unlocated !== null) {
      diagnostics.push({
        path: null,
        line: 0,
        column: 0,
        severity: unlocated[1],
        message: normalize(unlocated[2]),
      });
    }
  }
  return diagnostics;
}

// MARK: - Compilation

/**
 * @param {string} scratchPath
 * @param {boolean} build
 * @param {string} configuration
 */
function ensureModules(scratchPath, build, configuration) {
  if (build) {
    const result = spawnSync(
      "swift",
      ["build", "--scratch-path", scratchPath, "--configuration", configuration],
      {
        cwd: REPO_ROOT,
        encoding: "utf8",
        env: shippingManifestEnvironment(process.env),
        maxBuffer: 64 * 1024 * 1024,
      },
    );
    if (result.error) fail(`cannot run \`swift build\`: ${result.error.message}`);
    if (result.status !== 0) {
      process.stderr.write(result.stdout ?? "");
      process.stderr.write(result.stderr ?? "");
      fail(
        `\`swift build -c ${configuration}\` failed; ` +
          "the fixtures cannot be type-checked against the library",
      );
    }
  }
  const modules = join(scratchPath, configuration, "Modules");
  if (!existsSync(modules)) {
    fail(
      `no ${configuration} module directory at ${repoPath(modules)}; ` +
        "run without `--no-build`, or point `--scratch-path` at a built scratch directory",
    );
  }
  return modules;
}

/** @param {string[]} args */
function xcrun(args) {
  const result = spawnSync("xcrun", args, { encoding: "utf8", maxBuffer: 8 * 1024 * 1024 });
  if (result.error || result.status !== 0) return null;
  return (result.stdout ?? "").trim();
}

/**
 * Type-checks every fixture in ONE `swiftc` invocation.
 *
 * `-continue-building-after-errors` is load-bearing: without it the driver
 * stops after the first failing frontend job and the run silently reports only
 * the alphabetically-first fixture's diagnostics. `-diagnostic-style llvm`
 * keeps every diagnostic on one greppable `file:line:col: severity: message`
 * line instead of the default pretty-printed, source-quoting format.
 *
 * @param {string[]} files
 * @param {string} modulesPath
 * @param {{ flags: string[], target: string }} settings
 */
function typecheck(files, modulesPath, settings) {
  const sdk = xcrun(["--sdk", "macosx", "--show-sdk-path"]);
  const args = [
    "-typecheck",
    "-module-name",
    MODULE_NAME,
    "-target",
    settings.target,
    ...(sdk ? ["-sdk", sdk] : []),
    ...settings.flags,
    "-I",
    modulesPath,
    "-diagnostic-style",
    "llvm",
    "-no-color-diagnostics",
    "-continue-building-after-errors",
    ...files,
  ];
  const result = spawnSync("xcrun", ["swiftc", ...args], {
    cwd: REPO_ROOT,
    encoding: "utf8",
    maxBuffer: 64 * 1024 * 1024,
  });
  if (result.error) fail(`cannot run \`swiftc\`: ${result.error.message}`);
  return {
    args,
    status: result.status,
    output: `${result.stdout ?? ""}${result.stderr ?? ""}`,
  };
}

// MARK: - Main

function main() {
  const options = parseArgs(process.argv.slice(2));

  if (!existsSync(FIXTURE_ROOT) || !statSync(FIXTURE_ROOT).isDirectory()) {
    fail(`no fixtures directory at ${repoPath(FIXTURE_ROOT)}`);
  }

  const allFixtures = swiftFilesUnder(FIXTURE_ROOT).map(parseFixture);
  if (allFixtures.length === 0) fail(`no .swift fixtures under ${repoPath(FIXTURE_ROOT)}`);

  const fixtures =
    options.filter === null
      ? allFixtures
      : allFixtures.filter(
          (fixture) =>
            options.filter.test(fixture.relativePath) ||
            (fixture.scenario !== null && options.filter.test(fixture.scenario)),
        );
  if (fixtures.length === 0) {
    fail(
      `--filter ${options.filterSource} selected none of the ${allFixtures.length} fixtures; ` +
        "an empty selection is never a pass",
    );
  }

  if (options.list) {
    for (const fixture of fixtures) {
      process.stdout.write(
        `${fixture.scenario ?? "?"}\t${fixture.relativePath}\t${fixture.configuration}\t` +
          `${fixture.expectations.length} expectation(s)\n`,
      );
    }
    process.exit(0);
  }

  /** @type {Array<{ check: string, path: string, line: number, message: string, scenario: string | null }>} */
  const problems = [];
  /** @param {{ relativePath: string, scenario: string | null }} fixture */
  const report = (fixture, check, line, message) => {
    problems.push({ check, path: fixture.relativePath, line, message, scenario: fixture.scenario });
  };

  // Fixture-authoring problems come first: a malformed fixture cannot be
  // meaningfully matched against compiler output.
  for (const fixture of fixtures) {
    for (const item of fixture.diagnostics) {
      report(fixture, item.check, item.line, item.message);
    }
  }

  const seenScenarios = new Map();
  for (const fixture of fixtures) {
    if (fixture.scenario === null) continue;
    const previous = seenScenarios.get(fixture.scenario);
    if (previous !== undefined) {
      report(
        fixture,
        "scenario-owned-twice",
        1,
        `scenario ${fixture.scenario} is already proven by ${previous}`,
      );
    } else {
      seenScenarios.set(fixture.scenario, fixture.relativePath);
    }
  }

  if (options.checkScenarios) {
    const modes = readScenarioProofModes();
    if (modes !== null) {
      for (const fixture of fixtures) {
        const id = fixture.scenario;
        if (id === null || id.startsWith(HARNESS_PREFIX)) continue;
        if (!modes.has(id)) {
          report(fixture, "unknown-scenario", 1, `${id} is not declared in ${repoPath(SCENARIOS)}`);
        } else {
          const mode = modes.get(id);
          const release = fixture.configuration === "release";
          if (release ? !mode.releaseConfiguration : !mode.compileFail) {
            const required = release ? "(Proof: release configuration.)" : "(Proof: compile-fail.)";
            report(
              fixture,
              "wrong-proof-mode",
              1,
              `${id} is not marked \`${required}\` in ${repoPath(SCENARIOS)}`,
            );
          }
        }
      }
    }
  }

  const settings = compilerSettingsFromManifest();
  const byPath = new Map(fixtures.map((fixture) => [fixture.path, []]));
  const configurations = ["debug", "release"].filter((configuration) =>
    fixtures.some((fixture) => fixture.configuration === configuration),
  );
  let totalErrors = 0;
  for (const configuration of configurations) {
    const batch = fixtures.filter((fixture) => fixture.configuration === configuration);
    const modulesPath = ensureModules(options.scratchPath, options.build, configuration);
    const compilation = typecheck(
      batch.map((fixture) => fixture.path),
      modulesPath,
      settings,
    );
    const diagnostics = parseDiagnostics(compilation.output);
    const errors = diagnostics.filter((item) => item.severity === "error");
    totalErrors += errors.length;

    for (const error of errors) {
      const bucket = error.path === null ? undefined : byPath.get(error.path);
      if (bucket === undefined) {
        problems.push({
          check: "foreign-diagnostic",
          path: error.path === null ? "<compiler>" : repoPath(error.path),
          line: error.line,
          message: `error outside the fixture set: ${error.message}`,
          scenario: null,
        });
        continue;
      }
      bucket.push(error);
    }

    if (errors.length === 0 && compilation.status !== 0) {
      process.stderr.write(compilation.output);
      fail(
        `swiftc (${configuration}) exited ${compilation.status} ` +
          "without any parseable diagnostic (output above)",
      );
    }
  }

  /** @type {Array<{ scenario: string | null, path: string, ok: boolean, expectations: number, errors: number }>} */
  const summary = [];

  for (const fixture of fixtures) {
    const fixtureErrors = byPath.get(fixture.path) ?? [];
    const before = problems.length;

    if (fixtureErrors.length === 0) {
      report(
        fixture,
        "no-diagnostic",
        1,
        "fixture COMPILED CLEANLY — a compile-fail fixture that stops failing proves nothing; " +
          "either the guardrail regressed or the fixture is stale",
      );
    } else {
      const covered = new Set();
      for (const expectation of fixture.expectations) {
        const needle = normalize(expectation.text);
        let satisfied = false;
        for (const [index, error] of fixtureErrors.entries()) {
          if (!error.message.includes(needle)) continue;
          if (!expectation.anywhere && error.line !== expectation.line) continue;
          covered.add(index);
          satisfied = true;
        }
        if (!satisfied) {
          const where = expectation.anywhere
            ? "anywhere in this fixture"
            : `on line ${expectation.line}`;
          report(
            fixture,
            "missing-diagnostic",
            expectation.directiveLine,
            `no error ${where} contains \`${expectation.text}\`; the compiler emitted: ` +
              (fixtureErrors.map((error) => `${error.line}: ${error.message}`).join(" | ") ||
                "(nothing)"),
          );
        }
      }
      for (const [index, error] of fixtureErrors.entries()) {
        if (covered.has(index)) continue;
        report(
          fixture,
          "unexpected-diagnostic",
          error.line,
          `no expectation covers this error: ${error.message}`,
        );
      }
    }

    summary.push({
      scenario: fixture.scenario,
      path: fixture.relativePath,
      configuration: fixture.configuration,
      ok: problems.length === before,
      expectations: fixture.expectations.length,
      errors: fixtureErrors.length,
    });
  }

  // Fixtures that failed to parse are already marked failing above only if the
  // parse problem was recorded before their slot; fold those in too.
  for (const entry of summary) {
    if (problems.some((problem) => problem.path === entry.path)) entry.ok = false;
  }

  const failed = summary.filter((entry) => !entry.ok).length;

  if (options.json) {
    process.stdout.write(
      `${JSON.stringify(
        {
          fixtureRoot: repoPath(FIXTURE_ROOT),
          target: settings.target,
          flags: settings.flags,
          fixtures: summary,
          problems,
        },
        null,
        2,
      )}\n`,
    );
    process.exit(problems.length === 0 ? 0 : 1);
  }

  for (const entry of summary) {
    process.stdout.write(
      `${entry.ok ? "  ok  " : "FAIL  "}${(entry.scenario ?? "?").padEnd(12)} ` +
        `${entry.path} (${entry.expectations} expected, ${entry.errors} error(s))\n`,
    );
  }

  if (problems.length > 0) {
    process.stderr.write("\n");
    for (const problem of problems.sort(
      (a, b) => a.path.localeCompare(b.path) || a.line - b.line || a.check.localeCompare(b.check),
    )) {
      process.stderr.write(
        `${problem.path}:${problem.line}: error[${problem.check}]: ${problem.message}\n`,
      );
    }
    const checks = [...new Set(problems.map((problem) => problem.check))].sort();
    process.stderr.write(
      `\ncheck-compile-fail: FAILED — ${failed}/${summary.length} fixture(s) bad, ` +
        `${problems.length} problem(s) in ${checks.length} check(s): ${checks.join(", ")}\n`,
    );
    process.exit(1);
  }

  const expectations = summary.reduce((total, entry) => total + entry.expectations, 0);
  process.stdout.write(
    `check-compile-fail: OK — ${summary.length} fixture(s), ${expectations} expected ` +
      `diagnostic(s), ${totalErrors} compiler error(s), ` +
      `${configurations.length} batched swiftc pass(es) (${configurations.join(", ")}) ` +
      `[${settings.target}]\n`,
  );
}

main();
