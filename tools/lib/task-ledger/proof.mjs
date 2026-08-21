// Reading a task's `_Verify:_` line as commands, and expanding the scenario
// filters those commands carry.
//
// A `_Verify:_` field mixes prose with runnable commands, and only the
// commands inside inline code spans are runnable:
//
//     _Verify: `mise run test --filter 'CYCLE-01|CYCLE-02'` and
//     `mise run test:release --filter 'CYCLE-01|CYCLE-02'`._
//     _Verify: simulator `CogBoundaryTests` filtered to UI-11._
//
// The second form names a run in prose; it has a code span, but no command, so
// it contributes no filter. A scenario ID that appears only in prose is a
// description of the run, never a selection of tests, which is why the
// expansion rule reads code spans alone.
//
// Commands may carry environment prefixes (`MODE=release mise run …`)
// and may be negated (`! mise run test --filter DOES-NOT-EXIST` asserts the
// command *fails*, so it proves no coverage). Filters may be single-quoted,
// double-quoted, or bare.

/** Matches an inline code span. */
const CODE_SPAN_RE = /`([^`]+)`/g;

/** Matches a `mise run <command>` invocation inside a code span. */
const MISE_RUN_RE = /(?:^|[\s;&|(])mise\s+run\s+([A-Za-z][\w:.-]*)/g;

/** Matches the `--filter` argument of a command. */
const FILTER_RE = /--filter[=\s]+(?:'([^']*)'|"([^"]*)"|(\S+))/;

/**
 * Matches the run of `NAME=value` assignments immediately ahead of a command,
 * anchored to the end of the text that precedes it. `MODE=release
 * FEATURE=1 mise run test …` yields both assignments; a trailing
 * `--filter=x` does not, because an assignment has to start at a separator.
 */
const ENV_PREFIX_RE =
  /(?:^|[\s;&|(])((?:[A-Za-z_][A-Za-z0-9_]*=\S*)(?:\s+[A-Za-z_][A-Za-z0-9_]*=\S*)*)\s*$/;

/**
 * Reads the environment a command runs under from the text ahead of it.
 *
 * @param {string} before
 * @returns {Record<string, string>}
 */
function parseEnvPrefix(before) {
  /** @type {Record<string, string>} */
  const env = {};
  const match = ENV_PREFIX_RE.exec(before);
  if (match === null) return env;
  for (const token of match[1].split(/\s+/)) {
    const split = token.indexOf("=");
    env[token.slice(0, split)] = token.slice(split + 1);
  }
  return env;
}

/**
 * The mise commands that select tests by scenario filter. `test:compilefail`
 * is deliberately absent: compile-fail fixtures are a batched pass with no
 * filter, so a compile-fail scenario is never named by a filter expression.
 */
export const SCENARIO_FILTER_COMMANDS = new Set([
  "test",
  "test:lint",
  "test:matrix",
  "test:release",
  "test:arena-configurations",
]);

/**
 * Parses one `_Verify:_` field into the commands it runs.
 *
 * @param {string | null} verify
 * @returns {{command: string, filter: string | null, env: Record<string, string>, negated: boolean, text: string}[]}
 */
export function parseVerifyCommands(verify) {
  if (verify === null || verify === undefined) return [];
  /** @type {{command: string, filter: string | null, env: Record<string, string>, negated: boolean, text: string}[]} */
  const commands = [];

  for (const span of verify.matchAll(CODE_SPAN_RE)) {
    const body = span[1];
    const found = [...body.matchAll(MISE_RUN_RE)];
    for (let index = 0; index < found.length; index += 1) {
      const match = found[index];
      const start = match.index;
      const end = index + 1 < found.length ? found[index + 1].index : body.length;
      const before = body.slice(0, start);
      const text = body.slice(start, end).trim();
      const filterMatch = FILTER_RE.exec(text);
      commands.push({
        command: match[1],
        filter:
          filterMatch === null
            ? null
            : (filterMatch[1] ?? filterMatch[2] ?? filterMatch[3] ?? null),
        env: parseEnvPrefix(before),
        // `!` immediately ahead of this command, with nothing but separators
        // between, negates it: the command is expected to fail.
        negated: /![\s(]*$/.test(before),
        text,
      });
    }
  }
  return commands;
}

/**
 * Expands one filter expression against a scenario census.
 *
 * Test names begin with the hyphenated scenario ID, and the mise wrapper hands
 * the expression to `swift test --filter`, so the expression is a regular
 * expression matched — unanchored — against scenario IDs. `CYCLE` expands to
 * every CYCLE scenario; `DECL-0[1-5]` expands to five.
 *
 * @param {string} expression
 * @param {string[]} scenarioIds
 * @returns {{ids: string[], error: string | null}}
 */
export function expandFilter(expression, scenarioIds) {
  let pattern;
  try {
    pattern = new RegExp(expression);
  } catch (error) {
    return { ids: [], error: error.message };
  }
  return { ids: scenarioIds.filter((id) => pattern.test(id)), error: null };
}

/**
 * True when a task's commands select `scenarioId` through `command`.
 *
 * @param {{command: string, filter: string | null, negated: boolean}[]} commands
 * @param {string} command
 * @param {string} scenarioId
 */
export function selectsScenario(commands, command, scenarioId) {
  return commands.some((entry) => {
    if (entry.negated) return false;
    if (entry.command !== command) return false;
    if (entry.filter === null) return false;
    return expandFilter(entry.filter, [scenarioId]).ids.length === 1;
  });
}

/**
 * True when a task runs `command` at all, negations aside.
 *
 * @param {{command: string, negated: boolean}[]} commands
 * @param {string} command
 */
export function runsCommand(commands, command) {
  return commands.some((entry) => !entry.negated && entry.command === command);
}

/**
 * The vocabulary that names a benchmark's run or its recorded result. A
 * benchmark-gated scenario is proven by a benchmark run and by the measurement
 * or provisional threshold it lands in `perf.md` — never by a host unit test —
 * so its `_Verify:_` has to name one of those artifacts.
 */
const BENCHMARK_ARTIFACT_RE =
  /\b(?:bench|benchmark|benchmarks|baseline|baselines|malloc|mallocs|measure|measured|measurement|measurements|record|records|recorded|threshold|thresholds)\b|perf\.md/i;

/** @param {string} verify */
export function namesBenchmarkArtifact(verify) {
  return BENCHMARK_ARTIFACT_RE.test(verify);
}
