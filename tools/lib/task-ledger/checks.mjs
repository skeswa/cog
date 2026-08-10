// Checks over a parsed task ledger.
//
// Each check is a named function that returns diagnostics. `LEDGER_CHECKS` is
// the ordered registry the CLI runs; later ledger-integrity slices append
// their checks here rather than editing existing ones.

import { buildDependencyGraph, findCycles, reachableFrom, shortestPath } from "./graph.mjs";
import { isSplitAncestor } from "./parse.mjs";
import { emptyScenarioCensus } from "./scenarios.mjs";

/** Task types that may never carry a `_Greens:_` line. */
const GREENLESS_TASK_TYPES = ["Infrastructure", "Decision"];

/**
 * Resolves each milestone's terminal gate — the one _Gate_ task in that
 * milestone that transitively depends on every other gate there, and so is the
 * single point through which the milestone closes.
 *
 * The ledger's milestones do not all close through one gate: M1 has `M1-33c`
 * and `M1-32`, M2 has `M2-16` and `M2-20`, and M6 has three. In every case the
 * plan's milestone table names a closing *path* whose last link depends on the
 * earlier ones, so "reaches every other gate of its milestone" picks out that
 * last link without the checker having to read the plan. Requiring behavior to
 * be reachable from that terminal gate is strictly stronger than requiring it
 * from *any* gate: a behavior wired only into an early gate such as `M2-16`
 * would still have to reach the milestone's actual closing gate, which it does
 * exactly when the closing gate depends on the early one.
 *
 * @param {object[]} tasks
 * @param {Map<string, string[]>} graph
 */
function resolveMilestoneGates(tasks, graph) {
  /** @type {Map<string, object[]>} */
  const tasksByMilestone = new Map();
  for (const task of tasks) {
    const list = tasksByMilestone.get(task.milestone) ?? [];
    list.push(task);
    tasksByMilestone.set(task.milestone, list);
  }

  /** @type {Map<string, {milestone: string, tasks: object[], gates: object[], terminal: object | null, candidates: object[], reachable: Set<string>}>} */
  const milestones = new Map();
  for (const [milestone, milestoneTasks] of tasksByMilestone) {
    const gates = milestoneTasks.filter((task) => task.type === "Gate");
    const candidates = gates.filter((gate) => {
      const reachable = reachableFrom(graph, gate.id);
      return gates.every((other) => other.id === gate.id || reachable.has(other.id));
    });
    const terminal = candidates.length === 1 ? candidates[0] : null;
    milestones.set(milestone, {
      milestone,
      tasks: milestoneTasks,
      gates,
      candidates,
      terminal,
      reachable: terminal === null ? new Set() : reachableFrom(graph, terminal.id),
    });
  }
  return milestones;
}

/**
 * Shared, precomputed view of the ledger handed to every check.
 *
 * @param {string} path
 * @param {object[]} tasks
 * @param {{path: string, byId: Map<string, {id: string, line: number}>}} [scenarios]
 */
export function makeContext(path, tasks, scenarios) {
  const graph = buildDependencyGraph(tasks);
  const cycles = findCycles(graph);
  /** @type {Map<string, object>} */
  const byId = new Map();
  for (const task of tasks) {
    if (!byId.has(task.id)) byId.set(task.id, task);
  }
  const cyclicNodes = new Set(cycles.flat());

  const census = scenarios ?? emptyScenarioCensus(path);
  // Ownership counts every `_Greens:_` entry, whatever the owning task's type,
  // so a green on the wrong kind of task is reported as a misplaced line
  // rather than doubling as an unowned scenario.
  /** @type {Map<string, object[]>} */
  const ownersByScenario = new Map();
  for (const task of tasks) {
    for (const id of task.greens) {
      const owners = ownersByScenario.get(id) ?? [];
      owners.push(task);
      ownersByScenario.set(id, owners);
    }
  }

  return {
    path,
    tasks,
    graph,
    byId,
    cycles,
    cyclicNodes,
    scenarios: census,
    ownersByScenario,
    milestones: resolveMilestoneGates(tasks, graph),
  };
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
 * CHECK 6 — only behavior tasks and gates carry `_Greens:_`.
 *
 * Infrastructure unblocks later behavior but greens no scenario, and a
 * decision ends in a recorded choice. The finer rule — which proof modes a
 * *gate* may green — belongs to the proof-mode slice.
 */
function checkGreensTaskType(context) {
  const diagnostics = [];
  for (const task of context.tasks) {
    if (task.greens.length === 0) continue;
    if (!GREENLESS_TASK_TYPES.includes(task.type)) continue;
    diagnostics.push(
      diagnostic(
        "misplaced-greens",
        context,
        task,
        task.greensLine ?? task.line,
        `task ${task.id} is _(${task.type})_ and carries \`_Greens:_\` ` +
          `(${task.greens.join(", ")}); only behavior tasks and gates own scenarios`,
      ),
    );
  }
  return diagnostics;
}

/** CHECK 7 — every `_Greens:_` entry names a scenario the tree defines. */
function checkGreensNameKnownScenarios(context) {
  const diagnostics = [];
  for (const task of context.tasks) {
    for (const id of task.greens) {
      if (context.scenarios.byId.has(id)) continue;
      diagnostics.push(
        diagnostic(
          "unknown-scenario",
          context,
          task,
          task.greensLine ?? task.line,
          `task ${task.id} greens ${id}, which the scenario tree does not define`,
        ),
      );
    }
  }
  return diagnostics;
}

/** CHECK 8 — no scenario is owned by two tasks. */
function checkOneOwnerPerScenario(context) {
  const diagnostics = [];
  for (const [id, owners] of context.ownersByScenario) {
    if (owners.length < 2) continue;
    const names = owners.map((task) => `${task.id} (line ${task.greensLine ?? task.line})`);
    for (const task of owners.slice(1)) {
      diagnostics.push(
        diagnostic(
          "duplicate-scenario-owner",
          context,
          task,
          task.greensLine ?? task.line,
          `scenario ${id} is greened by ${owners.length} tasks — ${names.join(" and ")}; ` +
            `every scenario appears in exactly one \`_Greens:_\` line`,
        ),
      );
    }
  }
  return diagnostics;
}

/**
 * CHECK 9 — every scenario in the tree is owned by some task.
 *
 * The census comes from the scenario document itself, so a scenario added by a
 * decision task is unowned until a `_Greens:_` line claims it.
 */
function checkEveryScenarioOwned(context) {
  const diagnostics = [];
  for (const [id, scenario] of context.scenarios.byId) {
    if (context.ownersByScenario.has(id)) continue;
    diagnostics.push({
      check: "unowned-scenario",
      path: context.scenarios.path,
      line: scenario.line,
      taskId: null,
      message:
        `scenario ${id} appears in no task's \`_Greens:_\` line; ` +
        `every scenario is owned by exactly one task in the ledger`,
    });
  }
  return diagnostics;
}

/**
 * CHECK 10 — every milestone with behavior closes through one terminal gate.
 *
 * See `resolveMilestoneGates` for how the terminal gate is identified. Without
 * one, reachability has no anchor, so this check owns the failure and
 * `unreachable-behavior` stays quiet for that milestone.
 */
function checkMilestoneGateShape(context) {
  const diagnostics = [];
  for (const milestone of context.milestones.values()) {
    const behaviors = milestone.tasks.filter((task) => task.type === "Behavior");
    if (behaviors.length === 0) continue;
    if (milestone.terminal !== null) continue;
    const anchor = milestone.gates[0] ?? behaviors[0];
    if (milestone.gates.length === 0) {
      diagnostics.push(
        diagnostic(
          "milestone-gate",
          context,
          anchor,
          anchor.line,
          `milestone ${milestone.milestone} has ${behaviors.length} behavior task(s) but no ` +
            `_(Gate)_ task; a milestone's behavior is proven by its gate`,
        ),
      );
      continue;
    }
    diagnostics.push(
      diagnostic(
        "milestone-gate",
        context,
        anchor,
        anchor.line,
        `milestone ${milestone.milestone} has no single terminal gate: ` +
          `${milestone.gates.map((gate) => gate.id).join(", ")} ` +
          `(${milestone.candidates.length} of them depend on every other gate); ` +
          `gates of one milestone form a closing path`,
      ),
    );
  }
  return diagnostics;
}

/**
 * CHECK 11 — milestone gates cover every behavior by dependency.
 *
 * A behavior task must be reachable from its milestone's terminal gate, so
 * closing the milestone actually runs it. The sole exception is a task
 * carrying an explicit `_Non-blocking:_` policy; `non-blocking-policy` judges
 * whether that policy is well formed.
 */
function checkBehaviorReachableFromGate(context) {
  const diagnostics = [];
  for (const milestone of context.milestones.values()) {
    if (milestone.terminal === null) continue;
    for (const task of milestone.tasks) {
      if (task.type !== "Behavior") continue;
      if (task.nonBlocking !== null) continue;
      if (milestone.reachable.has(task.id)) continue;
      diagnostics.push(
        diagnostic(
          "unreachable-behavior",
          context,
          task,
          task.line,
          `behavior task ${task.id} is not reachable from its milestone's terminal gate ` +
            `${milestone.terminal.id} by dependency edges, so closing ${milestone.milestone} ` +
            `would not run it; add the edge or give the task a \`_Non-blocking:_\` policy`,
        ),
      );
    }
  }
  return diagnostics;
}

/**
 * CHECK 12 — a `_Non-blocking:_` line states an external-availability policy.
 *
 * The exception exists so unavailable hosted infrastructure cannot hold a
 * release hostage, which only means something if the line says when the task
 * does execute and what happens while it cannot.
 */
function checkNonBlockingPolicy(context) {
  const diagnostics = [];
  for (const task of context.tasks) {
    if (task.nonBlocking === null) continue;
    const line = task.nonBlockingLine ?? task.line;
    if (task.nonBlocking.length === 0) {
      diagnostics.push(
        diagnostic(
          "non-blocking-policy",
          context,
          task,
          line,
          `task ${task.id} has an empty \`_Non-blocking:_\` line; state when the task ` +
            `executes and what stays unblocked while it cannot`,
        ),
      );
      continue;
    }
    const statesExecution = /\bexecut(?:e|es|ed|ion)\b/i.test(task.nonBlocking);
    const statesCondition = /\b(?:when|unless|if|until)\b/i.test(task.nonBlocking);
    if (statesExecution && statesCondition) continue;
    diagnostics.push(
      diagnostic(
        "non-blocking-policy",
        context,
        task,
        line,
        `task ${task.id} has a \`_Non-blocking:_\` line that states no ` +
          `external-availability policy: "${task.nonBlocking}"; say when the task executes ` +
          `("execute when …", "execute only when …")`,
      ),
    );
  }
  return diagnostics;
}

/**
 * CHECK 13 — only tasks that need the exception carry it.
 *
 * A `_Non-blocking:_` task that its milestone's terminal gate already depends
 * on is blocking whatever the line claims, so the line is either wrong or the
 * dependency is.
 */
function checkNonBlockingNecessary(context) {
  const diagnostics = [];
  for (const milestone of context.milestones.values()) {
    if (milestone.terminal === null) continue;
    for (const task of milestone.tasks) {
      if (task.nonBlocking === null) continue;
      if (!milestone.reachable.has(task.id)) continue;
      diagnostics.push(
        diagnostic(
          "unnecessary-non-blocking",
          context,
          task,
          task.nonBlockingLine ?? task.line,
          `task ${task.id} carries a \`_Non-blocking:_\` policy but its milestone's terminal ` +
            `gate ${milestone.terminal.id} already depends on it; the exception is only for ` +
            `tasks a gate cannot cover`,
        ),
      );
    }
  }
  return diagnostics;
}

/**
 * The ordered check registry. Later ledger-integrity slices — the plan-to-task
 * contract, proof modes, and graph order — append entries here.
 */
export const LEDGER_CHECKS = [
  { name: "duplicate-task-id", run: checkDuplicateTaskIds },
  { name: "parent-child-coexistence", run: checkPrefixFreeTaskIds },
  { name: "unknown-dependency", run: checkDependenciesExist },
  { name: "redundant-dependency", run: checkTransitivelyMinimalDependencies },
  { name: "dependency-cycle", run: checkAcyclicGraph },
  { name: "misplaced-greens", run: checkGreensTaskType },
  { name: "unknown-scenario", run: checkGreensNameKnownScenarios },
  { name: "duplicate-scenario-owner", run: checkOneOwnerPerScenario },
  { name: "unowned-scenario", run: checkEveryScenarioOwned },
  { name: "milestone-gate", run: checkMilestoneGateShape },
  { name: "unreachable-behavior", run: checkBehaviorReachableFromGate },
  { name: "non-blocking-policy", run: checkNonBlockingPolicy },
  { name: "unnecessary-non-blocking", run: checkNonBlockingNecessary },
];

/**
 * Runs every registered check against a parsed ledger.
 *
 * @param {string} path
 * @param {object[]} tasks
 * @param {{path: string, byId: Map<string, {id: string, line: number}>}} [scenarios]
 * @returns {{diagnostics: object[], checkNames: string[], context: object}}
 */
export function runChecks(path, tasks, scenarios) {
  const context = makeContext(path, tasks, scenarios);
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
