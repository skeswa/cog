import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";

/**
 * Collects recognized value and flag options with one SwiftPM argument scan.
 *
 * @param {string[]} args
 * @param {{ value: string[], flags?: string[] }} recognized
 * @param {(message: string) => never} fail
 */
function extractArguments(args, recognized, fail) {
  const values = new Map(recognized.value.map((name) => [name, []]));
  const selected = [];
  const flags = new Set(recognized.flags ?? []);

  for (let index = 0; index < args.length; index += 1) {
    const argument = args[index];
    let matched = false;
    for (const name of recognized.value) {
      if (argument === name) {
        const value = args[index + 1];
        if (value === undefined) fail(`\`${name}\` was passed without a value`);
        values.get(name).push(value);
        selected.push(argument, value);
        index += 1;
        matched = true;
        break;
      }
      const prefix = `${name}=`;
      if (argument.startsWith(prefix)) {
        values.get(name).push(argument.slice(prefix.length));
        selected.push(argument);
        matched = true;
        break;
      }
    }
    if (!matched && flags.has(argument)) selected.push(argument);
  }
  return { selected, values };
}

/** Collects every `--filter <expr>` and `--filter=<expr>` value, in order. */
export function extractFilters(args, fail) {
  return extractArguments(args, { value: ["--filter"] }, fail).values.get("--filter");
}

/** Returns the SwiftPM trait options that affect package resolution. */
export function extractTraitArguments(args, fail) {
  return extractArguments(
    args,
    {
      value: ["--traits"],
      flags: ["--enable-all-traits", "--disable-default-traits"],
    },
    fail,
  ).selected;
}

/** Whether the extracted SwiftPM trait options enable one named trait. */
export function traitArgumentsEnable(traitArguments, trait) {
  if (traitArguments.includes("--enable-all-traits")) return true;
  return traitArguments.some((argument, index) => {
    let value;
    if (argument === "--traits") value = traitArguments[index + 1];
    else if (argument.startsWith("--traits=")) value = argument.slice("--traits=".length);
    return (
      value
        ?.split(",")
        .map((name) => name.trim())
        .includes(trait) ?? false
    );
  });
}

/** Whether an argument is a caller-supplied xUnit report destination. */
export function isXUnitArgument(argument) {
  return argument === "--xunit-output" || argument.startsWith("--xunit-output=");
}

/**
 * Keeps only test specifiers from `swift test list` stdout.
 *
 * Build progress normally goes to stderr, but only lines shaped like a Swift
 * Testing specifier (`Target.<something>`) are accepted so unrelated chatter
 * cannot make an empty test product look populated.
 */
export function parseSpecifiers(stdout) {
  return stdout
    .split("\n")
    .map((line) => line.trim())
    .filter((line) => /^\S+\.\S/.test(line));
}

/**
 * Fails before execution when any filter or top-level alternative is empty.
 *
 * SwiftPM exits successfully when a filter selects no tests. Checking each
 * alternative prevents a union such as `LINT-01|LINT-99` from hiding that one
 * of the two scenario claims has no test behind it.
 */
export function assertFiltersSelectTests(filters, specifiers, subject, fail) {
  const problems = [];
  for (const filter of filters) {
    if (selectionCount(filter, specifiers, fail) === 0) {
      problems.push(`filter selected no tests: ${filter}`);
      continue;
    }
    const alternatives = topLevelAlternatives(filter);
    if (alternatives.length < 2) continue;
    for (const alternative of alternatives) {
      if (selectionCount(alternative, specifiers, fail) === 0) {
        problems.push(
          `filter selected no tests for the alternative ${alternative} ` + `of ${filter}`,
        );
      }
    }
  }
  if (problems.length === 0) return;

  fail(
    `${problems.join("\nerror: ")}\n${subject} lists ${specifiers.length} ` +
      "test(s), and SwiftPM exits 0 on an empty selection, so the run was refused. " +
      "Run `swift test list` to see the available tests.",
  );
}

/**
 * Counts test cases in the xUnit files SwiftPM wrote for one invocation.
 *
 * Returns `undefined` only when no report exists and `requireReport` is false.
 * Cog's older root wrapper retains that compatibility mode; CogLint requires a
 * report because its executed count is part of every test command's contract.
 */
export function assertRunSelectedTests(
  filters,
  reportDirectory,
  subject,
  fail,
  { requireReport = false } = {},
) {
  let reports = 0;
  let executed = 0;
  for (const entry of readdirSync(reportDirectory)) {
    if (!entry.endsWith(".xml")) continue;
    reports += 1;
    const report = readFileSync(join(reportDirectory, entry), "utf8");
    for (const suite of report.matchAll(/<testsuite\b[^>]*\btests="(\d+)"/g)) {
      executed += Number(suite[1]);
    }
  }

  if (reports === 0) {
    if (requireReport) {
      fail(`${subject} produced no xUnit report, so its executed-test count is unknown.`);
    }
    return undefined;
  }
  if (executed > 0) return executed;

  const selection =
    filters.length === 0 ? "the unfiltered test run" : `filter(s) ${filters.join(", ")}`;
  fail(
    `${selection} executed zero tests for ${subject}, and SwiftPM reported ` +
      "that empty run as a success.",
  );
}

/** How many known specifiers `pattern` selects, using `swift test` semantics. */
function selectionCount(pattern, specifiers, fail) {
  let regex;
  try {
    // SwiftPM matches case-sensitively and without an implicit anchor against
    // the same specifier prefix `swift test list` prints.
    regex = new RegExp(pattern);
  } catch (error) {
    fail(`\`--filter ${pattern}\` is not a valid expression: ${error.message}`);
  }
  return specifiers.filter((specifier) => regex.test(specifier)).length;
}

/**
 * Splits a pattern on top-level `|`, ignoring escapes, classes, and groups.
 *
 * Exported because the task-ledger checker validates ledger filters with the
 * same splitting rule this guard enforces at run time, so the two can never
 * disagree about what "one alternative" means.
 */
export function topLevelAlternatives(pattern) {
  const branches = [];
  let branch = "";
  let depth = 0;
  let inCharacterClass = false;

  for (let index = 0; index < pattern.length; index += 1) {
    const character = pattern[index];
    if (character === "\\") {
      branch += character + (pattern[index + 1] ?? "");
      index += 1;
    } else if (inCharacterClass) {
      if (character === "]") inCharacterClass = false;
      branch += character;
    } else if (character === "[") {
      inCharacterClass = true;
      branch += character;
    } else if (character === "(") {
      depth += 1;
      branch += character;
    } else if (character === ")") {
      depth -= 1;
      branch += character;
    } else if (character === "|" && depth === 0) {
      branches.push(branch);
      branch = "";
    } else {
      branch += character;
    }
  }
  branches.push(branch);

  return branches.filter((candidate) => candidate.trim() !== "");
}
