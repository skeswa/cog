// Parser for the scenario tree (docs/swift/impl/scenarios.md).
//
// The scenario census is derived from this document rather than from a count
// maintained by hand, so adding a scenario immediately makes the ledger
// responsible for owning it.
//
// A scenario is defined by a top-level list item whose first token is a bolded
// ID and period:
//
//     - **DECL-01.** I declare one manual cog and read it back.
//
// Scenario IDs mentioned anywhere else — inside a sentence, in the tree
// summary, or in an indented sub-item — are references, not definitions.
//
// Every scenario also carries a proof mode: the class of check that can turn
// it green. `unit` is the default and is left unmarked; every other mode is a
// trailing `(Proof: ….)` on the scenario's own text. The marker is read from
// the scenario's wrapped body with whitespace normalized, because the real
// tree wraps several of them mid-marker:
//
//     - **TURN-07.** … Cog stops me with an error, in every kind of build.
//       (Proof: exit
//       test.)
//
// Prose elsewhere in the document may talk *about* `(Proof: ….)`; only the
// body of a scenario definition is scanned, so it is never mistaken for one.
//
// One group carries a different default: `## 18. PERF` is benchmark-gated in
// full, so its scenarios are `benchmark` without a per-scenario marker.

/** Matches a scenario definition: a top-level `- **ID.**` list item. */
const SCENARIO_DEF_RE = /^-\s+\*\*([A-Z][A-Z0-9]*-\d+)\.\*\*\s/;

/** Matches a numbered group heading, e.g. `## 18. PERF — Performance …`. */
const GROUP_HEADING_RE = /^##\s+(\d+)\.\s+([A-Z][A-Z0-9]*)\b/;

/** Matches a proof-mode marker anywhere in a scenario's normalized body. */
const PROOF_MARKER_RE = /\(Proof:\s*([^)]*)\)/g;

/** The group whose scenarios are benchmark-gated without a marker. */
const BENCHMARK_GROUP = 18;

/** The proof mode of an unmarked scenario outside the benchmark group. */
export const DEFAULT_PROOF_MODE = "unit";

/**
 * Every proof mode the tree defines, in the order its "How to use this
 * document" section lists them. A marker naming anything else is a typo the
 * checker refuses to guess at.
 */
export const PROOF_MODES = [
  "unit",
  "compile-fail",
  "exit test",
  "release configuration",
  "release absence",
  "simulator",
  "floor runtime",
  "suite",
  "benchmark",
];

/**
 * Collects the lines that belong to one scenario definition: the `- **ID.**`
 * line plus every wrapped continuation until a blank line, a heading, or the
 * next list item.
 *
 * @param {string[]} lines
 * @param {number} start index of the definition line
 */
function scenarioBody(lines, start) {
  const body = [lines[start]];
  let cursor = start + 1;
  while (cursor < lines.length) {
    const next = lines[cursor];
    if (next.trim().length === 0) break;
    if (next.startsWith("#")) break;
    if (/^\s*-\s/.test(next)) break;
    body.push(next);
    cursor += 1;
  }
  return { text: body.join(" ").replace(/\s+/g, " ").trim(), end: cursor };
}

/**
 * Parses the scenario tree into its census.
 *
 * @param {string} source Markdown text.
 * @param {string} path Path used in diagnostics.
 * @returns {{path: string, byId: Map<string, {id: string, line: number, mode: string, group: {number: number, tag: string} | null}>, ids: string[], modeCounts: Map<string, number>, diagnostics: object[]}}
 */
export function parseScenarios(source, path) {
  const lines = source.split("\n");
  /** @type {Map<string, {id: string, line: number, mode: string, group: {number: number, tag: string} | null}>} */
  const byId = new Map();
  /** @type {object[]} */
  const diagnostics = [];
  /** @type {{number: number, tag: string} | null} */
  let group = null;

  for (let index = 0; index < lines.length; index += 1) {
    const heading = GROUP_HEADING_RE.exec(lines[index]);
    if (heading !== null) {
      group = { number: Number(heading[1]), tag: heading[2] };
      continue;
    }

    const match = SCENARIO_DEF_RE.exec(lines[index]);
    if (match === null) continue;
    const id = match[1];
    const line = index + 1;
    const { text, end } = scenarioBody(lines, index);
    index = end - 1;

    const existing = byId.get(id);
    if (existing !== undefined) {
      diagnostics.push({
        check: "duplicate-scenario-id",
        path,
        line,
        taskId: null,
        message:
          `scenario ${id} is defined twice (lines ${existing.line}, ${line}); ` +
          `scenario IDs are stable and never reused`,
      });
      continue;
    }

    const markers = [...text.matchAll(PROOF_MARKER_RE)];
    const marked = markers.length === 0 ? null : markers.at(-1)[1].trim().replace(/\.$/, "").trim();
    const fallback =
      group !== null && group.number === BENCHMARK_GROUP ? "benchmark" : DEFAULT_PROOF_MODE;
    const mode = marked === null ? fallback : marked;

    if (!PROOF_MODES.includes(mode)) {
      diagnostics.push({
        check: "unknown-proof-mode",
        path,
        line,
        taskId: null,
        message:
          `scenario ${id} is marked \`(Proof: ${marked}.)\`, which is not a proof mode; ` +
          `the tree defines ${PROOF_MODES.join(", ")}`,
      });
      continue;
    }

    byId.set(id, { id, line, mode, group });
  }

  if (byId.size === 0) {
    diagnostics.push({
      check: "empty-scenario-census",
      path,
      line: 1,
      taskId: null,
      message:
        "no `- **ID.**` scenario definitions found; an empty census would make " +
        "every ownership check vacuous",
    });
  }

  /** @type {Map<string, number>} */
  const modeCounts = new Map();
  for (const scenario of byId.values()) {
    modeCounts.set(scenario.mode, (modeCounts.get(scenario.mode) ?? 0) + 1);
  }

  return { path, byId, ids: [...byId.keys()], modeCounts, diagnostics };
}

/** An empty census, used when no scenario document is available. */
export function emptyScenarioCensus(path) {
  return { path, byId: new Map(), ids: [], modeCounts: new Map(), diagnostics: [] };
}
