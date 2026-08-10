// Turns a parsed workflow document into the flat shape the checks read:
// triggers, the workflow-level `permissions:` block, and one record per job
// with its runner labels, guard expression, timeout, and steps.
//
// Everything here keeps the source line of whatever it describes, so a check
// can point at the offending key rather than at the top of the file.

import { entries, get, items, parseYaml, text } from "./yaml.mjs";

/**
 * @typedef {object} Trigger
 * @property {string} name
 * @property {number} line
 */

/**
 * @typedef {object} RunsOn
 * @property {"string" | "sequence" | "labels" | "expression" | "missing"} shape
 * @property {{value: string, line: number}[]} labels
 * @property {number} line
 */

/**
 * @typedef {object} Step
 * @property {number} index zero-based position in the job's `steps:` list
 * @property {number} line
 * @property {string | null} uses
 * @property {number} usesLine
 * @property {import("./yaml.mjs").Node | null | undefined} with
 */

/**
 * @typedef {object} Job
 * @property {string} id
 * @property {number} line
 * @property {RunsOn} runsOn
 * @property {string | null} condition the job's `if:` expression
 * @property {number} conditionLine
 * @property {import("./yaml.mjs").Node | null | undefined} permissions
 * @property {number} permissionsLine
 * @property {import("./yaml.mjs").Node | null | undefined} timeout
 * @property {number} timeoutLine
 * @property {string | null} reusable a job-level `uses:` (reusable workflow call)
 * @property {number} reusableLine
 * @property {Step[]} steps
 */

/**
 * @typedef {object} Workflow
 * @property {string} path
 * @property {string} name
 * @property {Trigger[]} triggers
 * @property {import("./yaml.mjs").Node | null | undefined} permissions
 * @property {number} permissionsLine
 * @property {Job[]} jobs
 * @property {{path: string, line: number, check: string, message: string}[]} diagnostics
 */

/**
 * @param {string} path
 * @param {string} source
 * @returns {Workflow}
 */
export function readWorkflow(path, source) {
  const { root, diagnostics } = parseYaml(source, path);

  const permissionsEntry = entryOf(root, "permissions");
  /** @type {Workflow} */
  const workflow = {
    path,
    name: text(get(root, "name")) ?? path,
    triggers: readTriggers(root),
    permissions: permissionsEntry?.value,
    permissionsLine: permissionsEntry?.line ?? 1,
    jobs: [],
    diagnostics,
  };

  for (const jobEntry of entries(get(root, "jobs"))) {
    workflow.jobs.push(readJob(jobEntry));
  }

  // A workflow with no readable job is either not a workflow or a document the
  // reader mis-parsed, and every check below is over jobs — so a silent pass
  // here would be a fail-open. Say so instead.
  if (workflow.jobs.length === 0) {
    workflow.diagnostics.push({
      path,
      line: entryOf(root, "jobs")?.line ?? 1,
      check: "yaml-parse",
      message: "no `jobs:` mapping with at least one job; nothing here can be verified",
    });
  }

  return workflow;
}

/**
 * @param {import("./yaml.mjs").Node | null | undefined} node
 * @param {string} key
 */
function entryOf(node, key) {
  if (node === null || node === undefined || node.kind !== "map") return undefined;
  return node.entries.find((item) => item.key === key);
}

/**
 * The event names a workflow reacts to. `on:` takes three shapes — a bare
 * scalar, a list, or a mapping of event to configuration — and all three are
 * flattened here so `no-pull-request-target` reads the real trigger key rather
 * than scanning the file for a substring. A comment mentioning
 * `pull_request_target` is stripped by the reader long before this point.
 *
 * @param {import("./yaml.mjs").Node | null | undefined} root
 * @returns {Trigger[]}
 */
function readTriggers(root) {
  const on = entryOf(root, "on");
  if (on === undefined || on.value === null || on.value === undefined) return [];
  const node = on.value;
  if (node.kind === "scalar") return [{ name: node.text, line: node.line }];
  if (node.kind === "seq") {
    return node.items
      .filter((item) => item.kind === "scalar")
      .map((item) => ({ name: /** @type {any} */ (item).text, line: item.line }));
  }
  return node.entries.map((item) => ({ name: item.key, line: item.line }));
}

/**
 * @param {import("./yaml.mjs").MapEntry} jobEntry
 * @returns {Job}
 */
function readJob(jobEntry) {
  const node = jobEntry.value;
  const condition = entryOf(node, "if");
  const permissions = entryOf(node, "permissions");
  const timeout = entryOf(node, "timeout-minutes");
  const reusable = entryOf(node, "uses");

  /** @type {Step[]} */
  const steps = [];
  let index = 0;
  for (const stepNode of items(get(node, "steps"))) {
    if (stepNode.kind !== "map") continue;
    const uses = entryOf(stepNode, "uses");
    steps.push({
      index,
      line: stepNode.line,
      uses: uses === undefined ? null : (text(uses.value) ?? ""),
      usesLine: uses?.line ?? stepNode.line,
      with: get(stepNode, "with"),
    });
    index += 1;
  }

  return {
    id: jobEntry.key,
    line: jobEntry.line,
    runsOn: readRunsOn(node, jobEntry.line),
    condition: condition === undefined ? null : (text(condition.value) ?? ""),
    conditionLine: condition?.line ?? jobEntry.line,
    permissions: permissions?.value,
    permissionsLine: permissions?.line ?? jobEntry.line,
    timeout: timeout?.value,
    timeoutLine: timeout?.line ?? jobEntry.line,
    reusable: reusable === undefined ? null : (text(reusable.value) ?? ""),
    reusableLine: reusable?.line ?? jobEntry.line,
    steps,
  };
}

/**
 * Normalizes the three `runs-on:` shapes — a label, a list of labels, or a
 * `{group, labels}` mapping — into one list of labels.
 *
 * @param {import("./yaml.mjs").Node | null | undefined} jobNode
 * @param {number} jobLine
 * @returns {RunsOn}
 */
function readRunsOn(jobNode, jobLine) {
  const runsOn = entryOf(jobNode, "runs-on");
  if (runsOn === undefined || runsOn.value === null || runsOn.value === undefined) {
    return { shape: "missing", labels: [], line: jobLine };
  }
  const node = runsOn.value;

  if (node.kind === "scalar") {
    const shape = node.text.includes("${{") ? "expression" : "string";
    return { shape, labels: [{ value: node.text, line: node.line }], line: runsOn.line };
  }

  if (node.kind === "seq") {
    return { shape: "sequence", labels: scalarLabels(node.items), line: runsOn.line };
  }

  // `runs-on: {group: …, labels: […]}`. A bare group with no labels still
  // resolves to a runner outside the hosted images, so it stays unlabelled and
  // the fail-closed rule in `self-hosted-guard` catches it.
  const labelsNode = get(node, "labels");
  const labels = labelsNode === null || labelsNode === undefined ? [] : items(labelsNode);
  return { shape: "labels", labels: scalarLabels(labels), line: runsOn.line };
}

/** @param {import("./yaml.mjs").Node[]} nodes */
function scalarLabels(nodes) {
  /** @type {{value: string, line: number}[]} */
  const labels = [];
  for (const node of nodes) {
    if (node.kind !== "scalar") continue;
    labels.push({ value: node.text, line: node.line });
  }
  return labels;
}
