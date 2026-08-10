// Parser for the Swift implementation task ledger (docs/swift/impl/tasks.md).
//
// The ledger is Markdown, but its task entries have a fixed shape that this
// parser treats as a grammar:
//
//     ## M0 tasks
//
//     - **M0-09aa** _(Infrastructure)_ — First sentence. More prose.
//       _Depends: M0-01, M0-02._
//       _Verify: `mise run tasks:check`._
//       _Greens: DECL-01, DECL-02._
//       _Non-blocking: execute only when the floor job exists._
//
// A task entry is one Markdown list item: the `- **ID**` line plus every
// following line until a blank line, a heading, or the next list item. Wrapped
// continuation lines are not required to be indented — the real ledger has
// several that start in column zero — so indentation is never load-bearing.

/** Matches a milestone section heading, e.g. `## M0 tasks`. */
const MILESTONE_HEADING_RE = /^##\s+(M\d+)\s+tasks\s*$/;

/** Matches the opening line of a task entry. */
const TASK_HEAD_RE = /^-\s+\*\*(.+?)\*\*\s+_\((.+?)\)_\s+—\s*(.*)$/;

/** Matches any list item that claims to be a task entry. */
const TASK_HEAD_CANDIDATE_RE = /^-\s+\*\*\s*M\d/;

/** Matches a field line inside a task entry. */
const FIELD_RE = /^_(Depends|Verify|Greens|Non-blocking):\s*(.*)$/;

/**
 * A task ID is `M<milestone>-<number>` followed by zero or more lowercase
 * letters. Splits append a letter recursively: `M1-07` → `M1-07a` → `M1-07aa`.
 */
export const TASK_ID_RE = /^M(\d+)-(\d+)([a-z]*)$/;

/** A scenario ID, e.g. `DECL-01` or `ASYNC-21`. */
const SCENARIO_ID_RE = /^[A-Z][A-Z0-9]*-\d+$/;

export const TASK_TYPES = ["Decision", "Infrastructure", "Behavior", "Gate", "Release"];

/**
 * Splits a task ID into its structural parts, or returns `null` when the ID
 * does not have the ledger's shape.
 *
 * @param {string} id
 * @returns {{milestone: number, number: number, suffix: string} | null}
 */
export function parseTaskId(id) {
  const match = TASK_ID_RE.exec(id);
  if (match === null) return null;
  return {
    milestone: Number(match[1]),
    number: Number(match[2]),
    suffix: match[3],
  };
}

/**
 * True when `a` is a proper split-ancestor of `b`: same milestone and number,
 * and `a`'s letter suffix is a proper prefix of `b`'s. `M1-07` is an ancestor
 * of `M1-07a` and `M1-07aa`; `M1-07a` and `M1-07b` are siblings.
 *
 * The comparison is structural rather than a raw string prefix so that
 * unrelated IDs whose text happens to nest — `M1-1` and `M1-11` — are not
 * mistaken for a retired parent beside its descendant.
 *
 * @param {{milestone: number, number: number, suffix: string}} a
 * @param {{milestone: number, number: number, suffix: string}} b
 */
export function isSplitAncestor(a, b) {
  if (a.milestone !== b.milestone) return false;
  if (a.number !== b.number) return false;
  if (a.suffix.length >= b.suffix.length) return false;
  return b.suffix.startsWith(a.suffix);
}

/** Strips the trailing `._` that closes every ledger field. */
function stripFieldTerminator(text) {
  return text.trim().replace(/_$/, "").replace(/\.$/, "").trim();
}

/**
 * Extracts the first sentence of a task description. A period only ends a
 * sentence when it is not part of a decimal number or a version string.
 *
 * @param {string} description
 */
function firstSentence(description) {
  const match = /^[\s\S]*?[^\d]\.(?=\s|$)/.exec(description);
  return match === null ? description.trim() : match[0].trim();
}

/**
 * Splits a comma-separated field body into trimmed, terminator-free items.
 *
 * @param {string} text
 */
function splitList(text) {
  return text
    .split(",")
    .map((item) => item.trim().replace(/\.$/, "").trim())
    .filter((item) => item.length > 0);
}

/**
 * Groups the raw lines of one task entry into its description and fields.
 *
 * @param {string} headRest first line's text after the em dash
 * @param {{text: string, line: number}[]} bodyLines
 */
function collectFields(headRest, bodyLines) {
  /** @type {{name: string, line: number, parts: string[]}[]} */
  const fields = [];
  const descriptionParts = headRest.trim().length > 0 ? [headRest.trim()] : [];

  for (const { text, line } of bodyLines) {
    const trimmed = text.trim();
    const fieldMatch = FIELD_RE.exec(trimmed);
    if (fieldMatch !== null) {
      fields.push({ name: fieldMatch[1], line, parts: [fieldMatch[2].trim()] });
      continue;
    }
    if (fields.length === 0) {
      descriptionParts.push(trimmed);
      continue;
    }
    fields.at(-1).parts.push(trimmed);
  }

  return { description: descriptionParts.join(" ").trim(), fields };
}

/**
 * Parses a task-ledger Markdown document.
 *
 * Structural problems (a malformed entry, an unknown type, a dependency that
 * is not a task ID) are reported as diagnostics rather than thrown, so one run
 * can surface every problem in the file.
 *
 * @param {string} source Markdown text.
 * @param {string} path Path used in diagnostics.
 * @returns {{tasks: object[], milestones: string[], diagnostics: object[]}}
 */
export function parseLedger(source, path) {
  const lines = source.split("\n");
  /** @type {object[]} */
  const tasks = [];
  /** @type {string[]} */
  const milestones = [];
  /** @type {object[]} */
  const diagnostics = [];

  const fail = (check, line, message) => {
    diagnostics.push({ check, path, line, taskId: null, message });
  };

  let milestone = null;

  for (let index = 0; index < lines.length; index += 1) {
    const raw = lines[index];
    const lineNumber = index + 1;

    const headingMatch = MILESTONE_HEADING_RE.exec(raw.trim());
    if (headingMatch !== null) {
      milestone = headingMatch[1];
      if (!milestones.includes(milestone)) milestones.push(milestone);
      continue;
    }

    if (!TASK_HEAD_CANDIDATE_RE.test(raw)) continue;

    const headMatch = TASK_HEAD_RE.exec(raw.trim());
    if (headMatch === null) {
      fail(
        "malformed-task-entry",
        lineNumber,
        `task entry does not match \`- **ID** _(Type)_ — description\`: ${raw.trim()}`,
      );
      continue;
    }

    // Gather the continuation lines that belong to this entry.
    /** @type {{text: string, line: number}[]} */
    const bodyLines = [];
    let cursor = index + 1;
    while (cursor < lines.length) {
      const next = lines[cursor];
      if (next.trim().length === 0) break;
      if (next.startsWith("#")) break;
      if (/^\s*-\s/.test(next)) break;
      bodyLines.push({ text: next, line: cursor + 1 });
      cursor += 1;
    }
    index = cursor - 1;

    const [, id, type, headRest] = headMatch;
    const { description, fields } = collectFields(headRest, bodyLines);

    if (parseTaskId(id) === null) {
      fail(
        "malformed-task-id",
        lineNumber,
        `task ID \`${id}\` is not \`M<milestone>-<number>\` plus zero or more lowercase split letters`,
      );
      continue;
    }
    if (!TASK_TYPES.includes(type)) {
      fail(
        "unknown-task-type",
        lineNumber,
        `task ${id} has type \`${type}\`; expected one of ${TASK_TYPES.join(", ")}`,
      );
      continue;
    }
    if (milestone === null) {
      fail("orphan-task", lineNumber, `task ${id} appears before any \`## M<n> tasks\` heading`);
      continue;
    }

    /** @type {Record<string, {line: number, text: string}>} */
    const fieldByName = {};
    for (const field of fields) {
      if (fieldByName[field.name] !== undefined) {
        fail("duplicate-field", field.line, `task ${id} repeats the \`_${field.name}:_\` field`);
        continue;
      }
      fieldByName[field.name] = {
        line: field.line,
        text: stripFieldTerminator(field.parts.join(" ")),
      };
    }

    /** @type {string[]} */
    const depends = [];
    const dependsField = fieldByName.Depends;
    if (dependsField !== undefined) {
      for (const item of splitList(dependsField.text)) {
        if (parseTaskId(item) === null) {
          fail(
            "malformed-dependency",
            dependsField.line,
            `task ${id} lists dependency \`${item}\`, which is not a task ID`,
          );
          continue;
        }
        depends.push(item);
      }
    }

    /** @type {string[]} */
    const greens = [];
    const greensField = fieldByName.Greens;
    if (greensField !== undefined) {
      for (const item of splitList(greensField.text)) {
        if (!SCENARIO_ID_RE.test(item)) {
          fail(
            "malformed-green",
            greensField.line,
            `task ${id} lists green \`${item}\`, which is not a scenario ID`,
          );
          continue;
        }
        greens.push(item);
      }
    }

    tasks.push({
      id,
      parts: parseTaskId(id),
      type,
      milestone,
      line: lineNumber,
      description,
      summary: firstSentence(description),
      depends,
      dependsLine: dependsField?.line ?? lineNumber,
      verify: fieldByName.Verify?.text ?? null,
      verifyLine: fieldByName.Verify?.line ?? null,
      greens,
      greensLine: fieldByName.Greens?.line ?? null,
      nonBlocking: fieldByName["Non-blocking"]?.text ?? null,
      nonBlockingLine: fieldByName["Non-blocking"]?.line ?? null,
    });
  }

  return { tasks, milestones, diagnostics };
}
