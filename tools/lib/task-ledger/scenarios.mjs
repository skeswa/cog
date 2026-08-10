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

/** Matches a scenario definition: a top-level `- **ID.**` list item. */
const SCENARIO_DEF_RE = /^-\s+\*\*([A-Z][A-Z0-9]*-\d+)\.\*\*\s/;

/**
 * Parses the scenario tree into its census.
 *
 * @param {string} source Markdown text.
 * @param {string} path Path used in diagnostics.
 * @returns {{path: string, byId: Map<string, {id: string, line: number}>, ids: string[], diagnostics: object[]}}
 */
export function parseScenarios(source, path) {
  const lines = source.split("\n");
  /** @type {Map<string, {id: string, line: number}>} */
  const byId = new Map();
  /** @type {object[]} */
  const diagnostics = [];

  for (let index = 0; index < lines.length; index += 1) {
    const match = SCENARIO_DEF_RE.exec(lines[index]);
    if (match === null) continue;
    const id = match[1];
    const line = index + 1;
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
    byId.set(id, { id, line });
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

  return { path, byId, ids: [...byId.keys()], diagnostics };
}

/** An empty census, used when no scenario document is available. */
export function emptyScenarioCensus(path) {
  return { path, byId: new Map(), ids: [], diagnostics: [] };
}
