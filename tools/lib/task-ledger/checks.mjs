// Checks over a parsed task ledger.
//
// Each check is a named function that returns diagnostics. `LEDGER_CHECKS` is
// the ordered registry the CLI runs; later ledger-integrity slices append
// their checks here rather than editing existing ones.

import { buildDependencyGraph, findCycles, shortestPath } from "./graph.mjs";
import { isSplitAncestor } from "./parse.mjs";

/**
 * Shared, precomputed view of the ledger handed to every check.
 *
 * @param {string} path
 * @param {object[]} tasks
 */
export function makeContext(path, tasks) {
  const graph = buildDependencyGraph(tasks);
  const cycles = findCycles(graph);
  /** @type {Map<string, object>} */
  const byId = new Map();
  for (const task of tasks) {
    if (!byId.has(task.id)) byId.set(task.id, task);
  }
  const cyclicNodes = new Set(cycles.flat());
  return { path, tasks, graph, byId, cycles, cyclicNodes };
}

/** Builds one diagnostic. */
function diagnostic(check, context, task, line, message) {
  return {
    check,
    path: context.path,
    line,
    taskId: task === null ? null : task.id,
    message,
  };
}

/** CHECK 1 — executable task IDs are unique. */
function checkDuplicateTaskIds(context) {
  /** @type {Map<string, object[]>} */
  const occurrences = new Map();
  for (const task of context.tasks) {
    const list = occurrences.get(task.id) ?? [];
    list.push(task);
    occurrences.set(task.id, list);
  }
  const diagnostics = [];
  for (const [id, list] of occurrences) {
    if (list.length < 2) continue;
    const lines = list.map((task) => task.line).join(", ");
    for (const task of list.slice(1)) {
      diagnostics.push(
        diagnostic(
          "duplicate-task-id",
          context,
          task,
          task.line,
          `task ID ${id} is defined ${list.length} times (lines ${lines}); IDs are never reused`,
        ),
      );
    }
  }
  return diagnostics;
}

/**
 * CHECK 2 — executable task IDs are prefix-free.
 *
 * Splitting a task retires its parent as an execution unit, so a retired split
 * parent may never reappear beside one of its descendants. Siblings such as
 * `M1-01a` and `M1-01b` are unrelated and always fine.
 */
function checkPrefixFreeTaskIds(context) {
  const diagnostics = [];
  const unique = [...context.byId.values()];
  for (const ancestor of unique) {
    for (const descendant of unique) {
      if (ancestor.id === descendant.id) continue;
      if (!isSplitAncestor(ancestor.parts, descendant.parts)) continue;
      diagnostics.push(
        diagnostic(
          "parent-child-coexistence",
          context,
          ancestor,
          ancestor.line,
          `split parent ${ancestor.id} (line ${ancestor.line}) coexists with its descendant ` +
            `${descendant.id} (line ${descendant.line}); a split parent is retired as an execution unit`,
        ),
      );
    }
  }
  return diagnostics;
}

/** CHECK 3 — every `_Depends:_` ID names an existing executable task. */
function checkDependenciesExist(context) {
  const diagnostics = [];
  for (const task of context.tasks) {
    for (const dep of task.depends) {
      if (dep === task.id) continue; // Reported as a cycle instead.
      if (context.byId.has(dep)) continue;
      diagnostics.push(
        diagnostic(
          "unknown-dependency",
          context,
          task,
          task.dependsLine,
          `task ${task.id} depends on ${dep}, which is not an executable task in this ledger`,
        ),
      );
    }
  }
  return diagnostics;
}

/**
 * CHECK 4 — dependency lists are transitively minimal.
 *
 * A listed dependency that is already reachable from another listed dependency
 * is a redundant edge: the ledger names only immediate prerequisites.
 * Duplicated entries in one list are redundant for the same reason.
 */
function checkTransitivelyMinimalDependencies(context) {
  const diagnostics = [];
  for (const task of context.tasks) {
    const listed = task.depends.filter((dep) => context.byId.has(dep));

    const seen = new Set();
    for (const dep of listed) {
      if (seen.has(dep)) {
        diagnostics.push(
          diagnostic(
            "redundant-dependency",
            context,
            task,
            task.dependsLine,
            `task ${task.id} lists dependency ${dep} more than once`,
          ),
        );
        continue;
      }
      seen.add(dep);
    }

    // A cyclic neighbourhood makes "already implied by" meaningless; the cycle
    // check owns those tasks until the loop is broken.
    if (context.cyclicNodes.has(task.id)) continue;
    if (listed.some((dep) => context.cyclicNodes.has(dep))) continue;

    for (const dep of new Set(listed)) {
      for (const other of new Set(listed)) {
        if (other === dep) continue;
        const path = shortestPath(context.graph, other, dep);
        if (path === null) continue;
        diagnostics.push(
          diagnostic(
            "redundant-dependency",
            context,
            task,
            task.dependsLine,
            `task ${task.id} lists ${dep}, which is already implied by ${other} via ${path.join(" -> ")}; ` +
              `\`_Depends:_\` names only immediate prerequisites`,
          ),
        );
      }
    }
  }
  return diagnostics;
}

/** CHECK 5 — the task graph is acyclic. */
function checkAcyclicGraph(context) {
  const diagnostics = [];
  for (const cycle of context.cycles) {
    const head = context.byId.get(cycle[0]) ?? null;
    diagnostics.push(
      diagnostic(
        "dependency-cycle",
        context,
        head,
        head?.line ?? 1,
        `dependency cycle: ${cycle.join(" -> ")}`,
      ),
    );
  }
  // A task that depends on itself never enters the DFS graph, so report it here.
  for (const task of context.tasks) {
    if (!task.depends.includes(task.id)) continue;
    diagnostics.push(
      diagnostic(
        "dependency-cycle",
        context,
        task,
        task.dependsLine,
        `dependency cycle: ${task.id} -> ${task.id}`,
      ),
    );
  }
  return diagnostics;
}

/**
 * The ordered check registry. Later ledger-integrity slices — scenario
 * ownership, gate reachability, non-blocking policy, the plan-to-task
 * contract, proof modes, and graph order — append entries here.
 */
export const LEDGER_CHECKS = [
  { name: "duplicate-task-id", run: checkDuplicateTaskIds },
  { name: "parent-child-coexistence", run: checkPrefixFreeTaskIds },
  { name: "unknown-dependency", run: checkDependenciesExist },
  { name: "redundant-dependency", run: checkTransitivelyMinimalDependencies },
  { name: "dependency-cycle", run: checkAcyclicGraph },
];

/**
 * Runs every registered check against a parsed ledger.
 *
 * @param {string} path
 * @param {object[]} tasks
 * @returns {{diagnostics: object[], checkNames: string[], context: object}}
 */
export function runChecks(path, tasks) {
  const context = makeContext(path, tasks);
  const diagnostics = [];
  for (const check of LEDGER_CHECKS) {
    diagnostics.push(...check.run(context));
  }
  return {
    diagnostics,
    checkNames: LEDGER_CHECKS.map((check) => check.name),
    context,
  };
}
