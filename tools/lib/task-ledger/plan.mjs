// Parser for the implementation plan's milestone map (docs/swift/impl/plan.md).
//
// The plan owns milestone intent and the task ledger owns executable slices,
// and the "Plan-to-task contract" section is where the two documents meet: one
// table row per milestone, each row linking to that milestone's task section
// and naming the decisions that gate dependent work plus the closing path.
//
//     | Plan milestone  | Task ledger                     | Decisions before dependent work | Closing path |
//     | --------------- | ------------------------------- | ------------------------------- | ------------ |
//     | M0: Scaffolding | [M0 tasks](./tasks.md#m0-tasks) | `M0-05a` runner topology        | `M0-10`      |
//
// Only that one table is read. It is found by its header cells rather than by
// position, so surrounding prose can move freely; renaming a column is a
// contract change and is reported as a missing map.

/** The header cells that identify the milestone map, lowercased. */
const HEADER_CELLS = [
  "plan milestone",
  "task ledger",
  "decisions before dependent work",
  "closing path",
];

/** Matches a Markdown link, capturing its text and target. */
const LINK_RE = /\[([^\]]*)\]\(([^)]+)\)/g;

/** Matches the milestone a row's first cell names, e.g. `M0: Scaffolding`. */
const MILESTONE_CELL_RE = /^\**\s*(M\d+)\b/;

/** Matches a task ID mentioned anywhere in a cell, backticked or bare. */
const TASK_MENTION_RE = /\bM\d+-\d+[a-z]*\b/g;

/**
 * Splits one Markdown table row into trimmed cells, or returns `null` when the
 * line is not a table row.
 *
 * @param {string} line
 */
function splitRow(line) {
  const trimmed = line.trim();
  if (!trimmed.startsWith("|")) return null;
  return trimmed
    .replace(/^\|/, "")
    .replace(/\|$/, "")
    .split("|")
    .map((cell) => cell.trim());
}

/** True for a `| --- | --- |` alignment row. */
function isSeparator(cells) {
  return cells.every((cell) => /^:?-{2,}:?$/.test(cell));
}

/** True when these cells are the milestone map's header. */
function isHeader(cells) {
  if (cells.length !== HEADER_CELLS.length) return false;
  return cells.every((cell, index) => cell.toLowerCase() === HEADER_CELLS[index]);
}

/**
 * Every Markdown link in a cell, as `{text, target}`.
 *
 * @param {string} cell
 */
function linksIn(cell) {
  return [...cell.matchAll(LINK_RE)].map((match) => ({ text: match[1], target: match[2].trim() }));
}

/**
 * Every distinct task ID a cell mentions, in order of first appearance.
 *
 * @param {string} cell
 */
function taskMentionsIn(cell) {
  return [...new Set(cell.match(TASK_MENTION_RE) ?? [])];
}

/**
 * Parses the plan's milestone map.
 *
 * @param {string} source Markdown text.
 * @param {string} path Path used in diagnostics.
 * @returns {{path: string, found: boolean, headerLine: number, rows: object[], byMilestone: Map<string, object[]>, diagnostics: object[]}}
 */
export function parsePlan(source, path) {
  const lines = source.split("\n");
  /** @type {object[]} */
  const rows = [];
  /** @type {object[]} */
  const diagnostics = [];

  let headerIndex = -1;
  for (let index = 0; index < lines.length; index += 1) {
    const cells = splitRow(lines[index]);
    if (cells !== null && isHeader(cells)) {
      headerIndex = index;
      break;
    }
  }

  if (headerIndex === -1) {
    diagnostics.push({
      check: "missing-plan-table",
      path,
      line: 1,
      taskId: null,
      message:
        "no milestone map found; the plan-to-task contract is a table whose header is " +
        `\`| ${HEADER_CELLS.join(" | ")} |\``,
    });
    return { path, found: false, headerLine: 1, rows, byMilestone: new Map(), diagnostics };
  }

  for (let index = headerIndex + 1; index < lines.length; index += 1) {
    const cells = splitRow(lines[index]);
    if (cells === null) break;
    if (isSeparator(cells)) continue;
    const line = index + 1;

    if (cells.length !== HEADER_CELLS.length) {
      diagnostics.push({
        check: "malformed-plan-row",
        path,
        line,
        taskId: null,
        message:
          `milestone map row has ${cells.length} cell(s), expected ${HEADER_CELLS.length}: ` +
          `${lines[index].trim()}`,
      });
      continue;
    }

    const milestoneMatch = MILESTONE_CELL_RE.exec(cells[0]);
    if (milestoneMatch === null) {
      diagnostics.push({
        check: "malformed-plan-row",
        path,
        line,
        taskId: null,
        message:
          `milestone map row starts with \`${cells[0]}\`, which names no milestone; ` +
          "every row begins `M<n>: <name>`",
      });
      continue;
    }

    rows.push({
      milestone: milestoneMatch[1],
      line,
      cells,
      label: cells[0],
      ledgerCell: cells[1],
      links: linksIn(cells[1]),
      decisionsCell: cells[2],
      closingCell: cells[3],
      mentions: [...new Set([...taskMentionsIn(cells[2]), ...taskMentionsIn(cells[3])])],
      text: cells.join(" | "),
    });
  }

  /** @type {Map<string, object[]>} */
  const byMilestone = new Map();
  for (const row of rows) {
    const list = byMilestone.get(row.milestone) ?? [];
    list.push(row);
    byMilestone.set(row.milestone, list);
  }

  return { path, found: true, headerLine: headerIndex + 1, rows, byMilestone, diagnostics };
}

/** An empty map, used when no plan document is available. */
export function emptyPlanMap(path) {
  return {
    path,
    found: false,
    headerLine: 1,
    rows: [],
    byMilestone: new Map(),
    diagnostics: [],
  };
}
