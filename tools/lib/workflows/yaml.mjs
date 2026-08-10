// A small YAML reader for the subset GitHub Actions workflows use, with a
// source line on every node.
//
// Why hand-rolled rather than shelling out to a real parser:
//
//   1. Every diagnostic this checker emits is `path:line: error[check]: …`, so
//      each node has to remember the line it came from. Piping a document
//      through `ruby -ryaml` or a vendored Python parser gives back plain data
//      with the lines thrown away.
//   2. No npm dependencies are allowed, and neither Ruby nor Python is a
//      pinned tool in `mise.toml`, so a shell-out would add an unpinned
//      runtime dependency to a check that must run in CI.
//   3. YAML 1.1 parsers (Psych, PyYAML) fold the bare key `on` into the
//      boolean `true`. That key is exactly the one `no-pull-request-target`
//      has to inspect, so the most convenient parsers are also the ones that
//      damage the input.
//
// Supported: block mappings and sequences, compact `- key: value` entries,
// plain/single-quoted/double-quoted scalars, multi-line plain scalars, block
// scalars (`|`/`>` with `-`/`+` chomping), single-line flow sequences and
// mappings, comments, anchors, aliases, and `<<:` merge keys.
//
// Not supported, and reported as a `yaml-parse` diagnostic rather than
// silently mis-read where detectable: multiple documents, multi-line flow
// collections, explicit tags, and `? key` complex mappings. Multi-line quoted
// scalars are not supported either; a workflow needing one should use a block
// scalar. Keys are never coerced — `on`, `true`, and `yes` all stay strings —
// while scalar *values* are coerced the YAML 1.2 core way (`true`/`false`,
// `null`/`~`, and numbers), which is what the `permissions:` and
// `persist-credentials:` checks want.

/**
 * @typedef {object} ScalarNode
 * @property {"scalar"} kind
 * @property {number} line
 * @property {string | number | boolean | null} value
 * @property {string} text raw text of the scalar, quotes and comment removed
 */

/**
 * @typedef {object} MapEntry
 * @property {string} key
 * @property {number} line line the key appears on
 * @property {Node | null} value
 */

/**
 * @typedef {object} MapNode
 * @property {"map"} kind
 * @property {number} line
 * @property {MapEntry[]} entries
 */

/**
 * @typedef {object} SeqNode
 * @property {"seq"} kind
 * @property {number} line
 * @property {Node[]} items
 */

/** @typedef {ScalarNode | MapNode | SeqNode} Node */

/** Characters that open a flow collection. */
const FLOW_OPENERS = new Set(["[", "{"]);

/**
 * Reads one YAML document.
 *
 * Always returns a result: parse problems become diagnostics and the reader
 * keeps going, so one malformed workflow cannot hide the checks on the rest.
 *
 * @param {string} text
 * @param {string} path used only in diagnostics
 * @returns {{root: Node | null, diagnostics: {path: string, line: number, check: string, message: string}[]}}
 */
export function parseYaml(text, path) {
  /** @type {State} */
  const state = {
    path,
    lines: text.split(/\r?\n/).map((raw, index) => ({ raw, number: index + 1 })),
    index: 0,
    anchors: new Map(),
    diagnostics: [],
  };

  skipIgnorable(state);
  const first = peek(state);
  if (first !== null && stripComment(first.raw).trim() === "---") {
    state.index += 1;
  }

  const root = parseBlockNode(state, 0);

  skipIgnorable(state);
  const trailing = peek(state);
  if (trailing !== null) {
    const rest = stripComment(trailing.raw).trim();
    if (rest === "---" || rest === "...") {
      fail(state, trailing.number, "multi-document YAML is not supported");
    } else {
      fail(state, trailing.number, `unparsed content: ${rest.slice(0, 60)}`);
    }
  }

  return { root, diagnostics: state.diagnostics };
}

/**
 * @typedef {object} State
 * @property {string} path
 * @property {{raw: string, number: number}[]} lines
 * @property {number} index
 * @property {Map<string, Node>} anchors
 * @property {{path: string, line: number, check: string, message: string}[]} diagnostics
 */

/**
 * @param {State} state
 * @param {number} line
 * @param {string} message
 */
function fail(state, line, message) {
  state.diagnostics.push({ path: state.path, line, check: "yaml-parse", message });
}

/** @param {State} state */
function peek(state) {
  return state.index < state.lines.length ? state.lines[state.index] : null;
}

/** Advances past blank lines and whole-line comments. @param {State} state */
function skipIgnorable(state) {
  while (state.index < state.lines.length) {
    const trimmed = state.lines[state.index].raw.trim();
    if (trimmed.length > 0 && !trimmed.startsWith("#")) return;
    state.index += 1;
  }
}

/** @param {string} raw */
function indentOf(raw) {
  let count = 0;
  while (count < raw.length && raw[count] === " ") count += 1;
  return count;
}

/**
 * Removes a trailing `#` comment, respecting quotes. A `#` only opens a
 * comment at the start of the content or after whitespace, which is what keeps
 * `uses: owner/action@sha # v1.2.3` a pin with a note rather than two tokens.
 *
 * @param {string} text
 */
export function stripComment(text) {
  let quote = "";
  for (let index = 0; index < text.length; index += 1) {
    const char = text[index];
    if (quote !== "") {
      if (char === "\\" && quote === '"') index += 1;
      else if (char === quote) quote = "";
      continue;
    }
    if (char === '"' || char === "'") {
      quote = char;
      continue;
    }
    if (char === "#" && (index === 0 || /\s/.test(text[index - 1]))) {
      return text.slice(0, index);
    }
  }
  return text;
}

/**
 * Parses whatever block node begins at the cursor, provided it is indented at
 * least `minIndent`. Returns `null` for an empty value.
 *
 * @param {State} state
 * @param {number} minIndent
 * @returns {Node | null}
 */
function parseBlockNode(state, minIndent) {
  skipIgnorable(state);
  const line = peek(state);
  if (line === null) return null;

  const indent = indentOf(line.raw);
  if (indent < minIndent) return null;

  const content = stripComment(line.raw).trim();
  if (content.length === 0) return null;

  if (content === "-" || content.startsWith("- ")) return parseSequence(state, indent);
  if (splitKey(content) !== null) return parseMapping(state, indent);

  // A bare block of text: a plain multi-line scalar standing on its own.
  return parsePlainScalar(state, content, line.number, indent, indent);
}

/**
 * @param {State} state
 * @param {number} indent
 * @returns {MapNode}
 */
function parseMapping(state, indent) {
  const start = peek(state);
  /** @type {MapNode} */
  const node = { kind: "map", line: start === null ? 1 : start.number, entries: [] };

  for (;;) {
    skipIgnorable(state);
    const line = peek(state);
    if (line === null) break;

    const lineIndent = indentOf(line.raw);
    if (lineIndent < indent) break;
    const content = stripComment(line.raw).trim();
    if (lineIndent > indent) {
      fail(state, line.number, `unexpected indentation: ${content.slice(0, 60)}`);
      state.index += 1;
      continue;
    }
    if (content === "-" || content.startsWith("- ")) break;

    const split = splitKey(content);
    if (split === null) break;

    state.index += 1;
    const entry = finishEntry(state, split, line.number, indent);
    if (entry.key === "<<") {
      mergeInto(state, node, entry.value, line.number);
      continue;
    }
    node.entries.push(entry);
  }

  return node;
}

/**
 * Completes one mapping entry whose key line the cursor has already passed.
 *
 * @param {State} state
 * @param {{key: string, rest: string}} split
 * @param {number} keyLine
 * @param {number} keyIndent
 * @returns {MapEntry}
 */
function finishEntry(state, split, keyLine, keyIndent) {
  const value =
    split.rest.length === 0
      ? parseBlockNode(state, keyIndent + 1)
      : parseInlineValue(state, split.rest, keyLine, keyIndent);
  return { key: split.key, line: keyLine, value };
}

/**
 * Splices a `<<:` merge into the mapping being built. Later keys already
 * present win, matching YAML merge semantics.
 *
 * @param {State} state
 * @param {MapNode} node
 * @param {Node | null} value
 * @param {number} line
 */
function mergeInto(state, node, value, line) {
  const sources = value === null ? [] : value.kind === "seq" ? value.items : [value];
  for (const source of sources) {
    if (source.kind !== "map") {
      fail(state, line, "merge key `<<` needs a mapping or a sequence of mappings");
      continue;
    }
    for (const entry of source.entries) {
      if (node.entries.some((existing) => existing.key === entry.key)) continue;
      node.entries.push(entry);
    }
  }
}

/**
 * @param {State} state
 * @param {number} indent
 * @returns {SeqNode}
 */
function parseSequence(state, indent) {
  const start = peek(state);
  /** @type {SeqNode} */
  const node = { kind: "seq", line: start === null ? 1 : start.number, items: [] };

  for (;;) {
    skipIgnorable(state);
    const line = peek(state);
    if (line === null) break;
    if (indentOf(line.raw) !== indent) break;

    const content = stripComment(line.raw).trimEnd();
    const body = content.slice(indent);
    if (body !== "-" && !body.startsWith("- ")) break;

    const rest = body.slice(1).replace(/^\s+/, "");
    const restIndent = indent + (body.length - rest.length);
    state.index += 1;

    if (rest.length === 0) {
      const item = parseBlockNode(state, indent + 1);
      node.items.push(item ?? { kind: "scalar", line: line.number, value: null, text: "" });
      continue;
    }

    const split = splitKey(rest);
    if (split !== null) {
      // `- key: value`: a compact mapping whose remaining keys line up under
      // the first key's column.
      /** @type {MapNode} */
      const map = { kind: "map", line: line.number, entries: [] };
      const entry = finishEntry(state, split, line.number, restIndent);
      if (entry.key === "<<") mergeInto(state, map, entry.value, line.number);
      else map.entries.push(entry);
      for (const more of parseMapping(state, restIndent).entries) {
        if (more.key === "<<") continue;
        map.entries.push(more);
      }
      node.items.push(map);
      continue;
    }

    node.items.push(parseInlineValue(state, rest, line.number, restIndent - 1));
  }

  return node;
}

/**
 * Parses a value written on the same line as its key (or its `-`), consuming
 * continuation lines when the value turns out to be a block scalar or a
 * multi-line plain scalar.
 *
 * @param {State} state
 * @param {string} rawText
 * @param {number} line
 * @param {number} ownerIndent indentation of the key or `-` that owns the value
 * @returns {Node}
 */
function parseInlineValue(state, rawText, line, ownerIndent) {
  let text = rawText.trim();

  /** @type {string | null} */
  let anchor = null;
  const anchorMatch = /^&([^\s]+)\s*/.exec(text);
  if (anchorMatch !== null) {
    anchor = anchorMatch[1];
    text = text.slice(anchorMatch[0].length);
  }

  /** @param {Node} node */
  const remember = (node) => {
    if (anchor !== null) state.anchors.set(anchor, node);
    return node;
  };

  if (text.length === 0) {
    const nested = parseBlockNode(state, ownerIndent + 1);
    return remember(nested ?? { kind: "scalar", line, value: null, text: "" });
  }

  if (text.startsWith("*")) {
    const name = text.slice(1).trim();
    const target = state.anchors.get(name);
    if (target === undefined) {
      fail(state, line, `alias \`*${name}\` has no anchor`);
      return { kind: "scalar", line, value: null, text: "" };
    }
    return target;
  }

  if (text[0] === "|" || text[0] === ">") {
    return remember(parseBlockScalar(state, text, line, ownerIndent));
  }

  if (FLOW_OPENERS.has(text[0])) {
    return remember(parseFlow(state, text, line));
  }

  if (text[0] === '"' || text[0] === "'") {
    return remember({ kind: "scalar", line, value: unquote(text), text: unquote(text) });
  }

  return remember(parsePlainScalar(state, text, line, ownerIndent, ownerIndent + 1));
}

/**
 * A plain scalar plus any more-indented continuation lines, folded with single
 * spaces. This is how multi-line `if:` conditions are written when the author
 * does not reach for a folded block scalar.
 *
 * @param {State} state
 * @param {string} first
 * @param {number} line
 * @param {number} ownerIndent
 * @param {number} minContinuation
 * @returns {ScalarNode}
 */
function parsePlainScalar(state, first, line, ownerIndent, minContinuation) {
  const parts = [first.trim()];
  for (;;) {
    const next = peek(state);
    if (next === null) break;
    const trimmed = next.raw.trim();
    if (trimmed.length === 0 || trimmed.startsWith("#")) break;
    const nextIndent = indentOf(next.raw);
    if (nextIndent < minContinuation || nextIndent <= ownerIndent) break;
    const content = stripComment(next.raw).trim();
    if (content.startsWith("- ") || content === "-" || splitKey(content) !== null) break;
    parts.push(content);
    state.index += 1;
  }
  const text = parts.join(" ");
  return { kind: "scalar", line, value: coerce(text), text };
}

/**
 * @param {State} state
 * @param {string} header `|`, `>-`, `|+2`, …
 * @param {number} line
 * @param {number} ownerIndent
 * @returns {ScalarNode}
 */
function parseBlockScalar(state, header, line, ownerIndent) {
  const style = header[0];
  const explicit = /(\d+)/.exec(header.slice(1));
  const chomp = header.includes("-") ? "strip" : header.includes("+") ? "keep" : "clip";

  /** @type {string[]} */
  const raw = [];
  let baseIndent = explicit === null ? -1 : ownerIndent + Number(explicit[1]);

  for (;;) {
    const next = peek(state);
    if (next === null) break;
    if (next.raw.trim().length === 0) {
      raw.push("");
      state.index += 1;
      continue;
    }
    const nextIndent = indentOf(next.raw);
    if (nextIndent <= ownerIndent) break;
    if (baseIndent < 0) baseIndent = nextIndent;
    if (nextIndent < baseIndent) break;
    raw.push(next.raw.slice(baseIndent));
    state.index += 1;
  }

  while (raw.length > 0 && raw[raw.length - 1] === "") raw.pop();

  let text;
  if (style === "|") {
    text = raw.join("\n");
  } else {
    /** @type {string[]} */
    const folded = [];
    for (const item of raw) {
      if (item === "") {
        folded.push("\n");
        continue;
      }
      if (folded.length > 0 && !folded[folded.length - 1].endsWith("\n")) folded.push(" ");
      folded.push(item);
    }
    text = folded.join("");
  }
  if (chomp !== "strip" && raw.length > 0) text += "\n";

  return { kind: "scalar", line, value: text, text };
}

/**
 * Single-line flow collections: `[a, b]` and `{a: b}`, nestable.
 *
 * @param {State} state
 * @param {string} text
 * @param {number} line
 * @returns {Node}
 */
function parseFlow(state, text, line) {
  const cursor = { text, index: 0 };
  const node = parseFlowNode(state, cursor, line);
  skipFlowSpace(cursor);
  if (cursor.index < cursor.text.length) {
    fail(state, line, `trailing text after flow collection: ${cursor.text.slice(cursor.index)}`);
  }
  return node;
}

/** @param {{text: string, index: number}} cursor */
function skipFlowSpace(cursor) {
  while (cursor.index < cursor.text.length && /\s/.test(cursor.text[cursor.index])) {
    cursor.index += 1;
  }
}

/**
 * @param {State} state
 * @param {{text: string, index: number}} cursor
 * @param {number} line
 * @returns {Node}
 */
function parseFlowNode(state, cursor, line) {
  skipFlowSpace(cursor);
  const char = cursor.text[cursor.index];

  if (char === "[") {
    cursor.index += 1;
    /** @type {SeqNode} */
    const node = { kind: "seq", line, items: [] };
    for (;;) {
      skipFlowSpace(cursor);
      if (cursor.index >= cursor.text.length) {
        fail(state, line, "unterminated flow sequence (multi-line flow is not supported)");
        break;
      }
      if (cursor.text[cursor.index] === "]") {
        cursor.index += 1;
        break;
      }
      node.items.push(parseFlowNode(state, cursor, line));
      skipFlowSpace(cursor);
      if (cursor.text[cursor.index] === ",") cursor.index += 1;
    }
    return node;
  }

  if (char === "{") {
    cursor.index += 1;
    /** @type {MapNode} */
    const node = { kind: "map", line, entries: [] };
    for (;;) {
      skipFlowSpace(cursor);
      if (cursor.index >= cursor.text.length) {
        fail(state, line, "unterminated flow mapping (multi-line flow is not supported)");
        break;
      }
      if (cursor.text[cursor.index] === "}") {
        cursor.index += 1;
        break;
      }
      const key = readFlowScalar(cursor, ":,}]");
      skipFlowSpace(cursor);
      let value = null;
      if (cursor.text[cursor.index] === ":") {
        cursor.index += 1;
        value = parseFlowNode(state, cursor, line);
      }
      node.entries.push({ key: unquote(key.trim()), line, value });
      skipFlowSpace(cursor);
      if (cursor.text[cursor.index] === ",") cursor.index += 1;
    }
    return node;
  }

  const scalar = readFlowScalar(cursor, ",}]").trim();
  const text = unquote(scalar);
  return { kind: "scalar", line, value: isQuoted(scalar) ? text : coerce(text), text };
}

/**
 * @param {{text: string, index: number}} cursor
 * @param {string} stops
 */
function readFlowScalar(cursor, stops) {
  const start = cursor.index;
  let quote = "";
  while (cursor.index < cursor.text.length) {
    const char = cursor.text[cursor.index];
    if (quote !== "") {
      if (char === "\\" && quote === '"') cursor.index += 1;
      else if (char === quote) quote = "";
      cursor.index += 1;
      continue;
    }
    if (char === '"' || char === "'") {
      quote = char;
      cursor.index += 1;
      continue;
    }
    if (stops.includes(char)) break;
    cursor.index += 1;
  }
  return cursor.text.slice(start, cursor.index);
}

/**
 * Splits `key: value` (or a bare `key:`) into its parts, or returns `null`
 * when the text is not a mapping entry. Quoted keys are unquoted.
 *
 * @param {string} content
 * @returns {{key: string, rest: string} | null}
 */
export function splitKey(content) {
  if (content.startsWith("? ")) return null;

  if (content[0] === '"' || content[0] === "'") {
    const quote = content[0];
    let index = 1;
    while (index < content.length) {
      if (content[index] === "\\" && quote === '"') index += 2;
      else if (content[index] === quote) break;
      else index += 1;
    }
    if (index >= content.length) return null;
    const after = content.slice(index + 1).trimStart();
    if (!after.startsWith(":")) return null;
    return { key: unquote(content.slice(0, index + 1)), rest: after.slice(1).trim() };
  }

  let depth = 0;
  for (let index = 0; index < content.length; index += 1) {
    const char = content[index];
    if (char === "{" || char === "[") depth += 1;
    else if (char === "}" || char === "]") depth -= 1;
    else if (char === "#") break;
    else if (char === ":" && depth === 0) {
      const next = content[index + 1];
      if (next !== undefined && next !== " ") continue;
      const key = content.slice(0, index).trim();
      if (key.length === 0 || /\s/.test(key)) return null;
      return { key, rest: content.slice(index + 1).trim() };
    }
  }
  return null;
}

/** @param {string} text */
function isQuoted(text) {
  return (
    text.length >= 2 &&
    ((text[0] === '"' && text.endsWith('"')) || (text[0] === "'" && text.endsWith("'")))
  );
}

/** @param {string} text */
function unquote(text) {
  if (!isQuoted(text)) return text;
  const body = text.slice(1, -1);
  if (text[0] === "'") return body.replaceAll("''", "'");
  return body
    .replaceAll("\\n", "\n")
    .replaceAll('\\"', '"')
    .replaceAll("\\'", "'")
    .replaceAll("\\\\", "\\");
}

/**
 * YAML 1.2 core-schema coercion for plain scalars. Keys never go through here,
 * so `on:` stays `on`.
 *
 * @param {string} text
 * @returns {string | number | boolean | null}
 */
function coerce(text) {
  if (text === "" || text === "~" || text === "null" || text === "Null" || text === "NULL") {
    return null;
  }
  if (text === "true" || text === "True" || text === "TRUE") return true;
  if (text === "false" || text === "False" || text === "FALSE") return false;
  if (/^[-+]?\d+$/.test(text)) return Number(text);
  if (/^[-+]?(\d+\.\d*|\.\d+)([eE][-+]?\d+)?$/.test(text)) return Number(text);
  return text;
}

// ---------------------------------------------------------------------------
// Accessors
// ---------------------------------------------------------------------------

/**
 * @param {Node | null | undefined} node
 * @param {string} key
 * @returns {MapEntry | undefined}
 */
export function entry(node, key) {
  if (node === null || node === undefined || node.kind !== "map") return undefined;
  return node.entries.find((item) => item.key === key);
}

/**
 * @param {Node | null | undefined} node
 * @param {string} key
 * @returns {Node | null | undefined}
 */
export function get(node, key) {
  return entry(node, key)?.value;
}

/**
 * @param {Node | null | undefined} node
 * @returns {MapEntry[]}
 */
export function entries(node) {
  if (node === null || node === undefined || node.kind !== "map") return [];
  return node.entries;
}

/**
 * @param {Node | null | undefined} node
 * @returns {Node[]}
 */
export function items(node) {
  if (node === null || node === undefined) return [];
  if (node.kind === "seq") return node.items;
  return [node];
}

/**
 * The scalar text of a node, or `null` when it is not a scalar.
 *
 * @param {Node | null | undefined} node
 * @returns {string | null}
 */
export function text(node) {
  if (node === null || node === undefined || node.kind !== "scalar") return null;
  return node.text;
}
