// Dependency-graph helpers for the task ledger.
//
// Edges point from a task to each task it depends on, matching the direction
// of the ledger's `_Depends:_` field. Every traversal here is iterative and
// visited-guarded, so a cyclic graph is still safe to walk.

/**
 * Builds an adjacency map from task ID to its dependency IDs, keeping only
 * edges whose endpoints both exist.
 *
 * @param {{id: string, depends: string[]}[]} tasks
 * @returns {Map<string, string[]>}
 */
export function buildDependencyGraph(tasks) {
  const known = new Set(tasks.map((task) => task.id));
  /** @type {Map<string, string[]>} */
  const graph = new Map();
  for (const task of tasks) {
    if (graph.has(task.id)) continue; // Duplicate ID: keep the first entry.
    graph.set(
      task.id,
      task.depends.filter((dep) => known.has(dep) && dep !== task.id),
    );
  }
  return graph;
}

/**
 * Shortest dependency path from `from` to `to`, exclusive of `from` being
 * equal to `to` at zero length. Returns `null` when `to` is unreachable.
 *
 * @param {Map<string, string[]>} graph
 * @param {string} from
 * @param {string} to
 * @returns {string[] | null} path including both endpoints
 */
export function shortestPath(graph, from, to) {
  /** @type {Map<string, string | null>} */
  const parent = new Map([[from, null]]);
  const queue = [from];
  while (queue.length > 0) {
    const current = queue.shift();
    for (const next of graph.get(current) ?? []) {
      if (parent.has(next)) continue;
      parent.set(next, current);
      if (next === to) {
        const path = [to];
        let step = current;
        while (step !== null && step !== undefined) {
          path.push(step);
          step = parent.get(step);
        }
        return path.reverse();
      }
      queue.push(next);
    }
  }
  return null;
}

/**
 * Finds dependency cycles, one per back edge discovered by depth-first search
 * and deduplicated by rotation-independent identity.
 *
 * @param {Map<string, string[]>} graph
 * @returns {string[][]} each cycle as `[a, b, ..., a]`
 */
export function findCycles(graph) {
  const WHITE = 0;
  const GREY = 1;
  const BLACK = 2;
  /** @type {Map<string, number>} */
  const color = new Map([...graph.keys()].map((id) => [id, WHITE]));
  /** @type {string[][]} */
  const cycles = [];
  const seen = new Set();

  for (const root of graph.keys()) {
    if (color.get(root) !== WHITE) continue;

    /** @type {string[]} */
    const stack = [];
    /** @type {{id: string, next: number}[]} */
    const frames = [{ id: root, next: 0 }];
    color.set(root, GREY);
    stack.push(root);

    while (frames.length > 0) {
      const frame = frames.at(-1);
      const neighbors = graph.get(frame.id) ?? [];
      if (frame.next >= neighbors.length) {
        color.set(frame.id, BLACK);
        frames.pop();
        stack.pop();
        continue;
      }
      const next = neighbors[frame.next];
      frame.next += 1;
      const nextColor = color.get(next) ?? WHITE;
      if (nextColor === GREY) {
        const start = stack.indexOf(next);
        const cycle = [...stack.slice(start), next];
        const key = canonicalCycleKey(cycle);
        if (!seen.has(key)) {
          seen.add(key);
          cycles.push(cycle);
        }
        continue;
      }
      if (nextColor === WHITE) {
        color.set(next, GREY);
        stack.push(next);
        frames.push({ id: next, next: 0 });
      }
    }
  }

  return cycles;
}

/**
 * Rotation-independent identity for a cycle so the same loop found from two
 * roots is reported once.
 *
 * @param {string[]} cycle `[a, b, ..., a]`
 */
function canonicalCycleKey(cycle) {
  const nodes = cycle.slice(0, -1);
  let best = null;
  for (let offset = 0; offset < nodes.length; offset += 1) {
    const rotation = [...nodes.slice(offset), ...nodes.slice(0, offset)].join(">");
    if (best === null || rotation < best) best = rotation;
  }
  return best ?? "";
}
