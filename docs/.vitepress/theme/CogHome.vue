<script setup lang="ts">
import { computed, onMounted, onBeforeUnmount, ref } from "vue";
import { useData, withBase } from "vitepress";

/**
 * The landing page.
 *
 * The centrepiece is a working model of the graph rather than a picture of
 * one. Cog's whole claim is that a change settles exactly the values that
 * depend on it and notifies exactly the views that read them — so the page
 * runs that algorithm on a real eight-node graph and reports what it did.
 * The equal-value cutoff is the part worth seeing: nudging the temperature
 * within a band re-runs one selector, changes nothing, and redraws no views.
 *
 * The simulation below mirrors the documented semantics exactly: mark
 * downstream of the write, recompute in dependency order, and stop descending
 * wherever a value came back equal.
 *
 * A second model carries the graph to its outside edge. It pairs the source of
 * one named mechanism with a three-lane picture of the runtime, and plays a
 * turn through them a beat at a time — the write settles, then the watch runs,
 * then the notification leaves — because ordering is the part a static diagram
 * cannot show. The last beat posts a toast pinned to the viewport rather than
 * drawing one inside the model, so the effect genuinely leaves everything the
 * section has drawn. Closing the gate takes the watch with it, which is what
 * the faded lines and the severed arrow are there to make obvious.
 */

type NodeKind = "source" | "derived" | "view";

interface GraphNode {
  id: string;
  label: string;
  kind: NodeKind;
  x: number;
  y: number;
  /** Dependency order. A node never precedes anything it reads. */
  rank: number;
}

const NODES: GraphNode[] = [
  { id: "temperature", label: "temperature", kind: "source", x: 8, y: 26, rank: 0 },
  { id: "zip", label: "zip", kind: "source", x: 8, y: 74, rank: 0 },
  { id: "advice", label: "advice", kind: "derived", x: 37, y: 20, rank: 1 },
  { id: "city", label: "city", kind: "derived", x: 37, y: 80, rank: 1 },
  { id: "headline", label: "headline", kind: "derived", x: 63, y: 50, rank: 2 },
  { id: "AdviceLabel", label: "AdviceLabel", kind: "view", x: 90, y: 14, rank: 3 },
  { id: "Banner", label: "Banner", kind: "view", x: 90, y: 50, rank: 3 },
  { id: "CityTitle", label: "CityTitle", kind: "view", x: 90, y: 86, rank: 3 },
];

/** `from` is read by `to`, so a change in `from` can reach `to`. */
const EDGES: Array<[string, string]> = [
  ["temperature", "advice"],
  ["zip", "city"],
  ["advice", "headline"],
  ["city", "headline"],
  ["advice", "AdviceLabel"],
  ["headline", "Banner"],
  ["city", "CityTitle"],
];

/**
 * The appearance comes from VitePress rather than from a `html.dark`
 * descendant selector. Vue's scoped-style compiler rewrites
 * `:global(html.dark) .cog` down to bare `html.dark`, which sets the tokens on
 * the document element where the component's own `.cog` rule then overrides
 * them — so the dark palette silently never applied. Binding the class here
 * keeps both palettes on the same element at the same specificity.
 */
const { isDark } = useData();

declare const __COG_SWIFT_RELEASE__: string;
const swiftRelease = __COG_SWIFT_RELEASE__;
const selectedPlatform = ref<"swift" | "kotlin">("swift");

/**
 * The two things a reader actually needs to paste. Xcode's "Add Package
 * Dependencies…" field takes the bare repository URL and nothing else, so that
 * route gets the URL on its own line rather than buried inside a manifest
 * snippet the dialog would reject.
 *
 * Both are derived from the released version rather than written out, so the
 * page can never advertise a version Release Please has already moved past.
 */
const packageURL = "https://github.com/skeswa/cog.git";
const manifestSnippet = computed(
  () => `.package(
  url: "${packageURL}",
  .upToNextMinor(from: "${swiftRelease}")
)`,
);

/**
 * Copying is the whole point of an install block, so each copyable thing
 * carries its own key and the button reports back in place. The key, not a
 * boolean, is what distinguishes "the URL was copied" from "the manifest was
 * copied" when both buttons are on screen at once.
 */
const copiedKey = ref<string | null>(null);
let copiedTimer: ReturnType<typeof setTimeout> | undefined;

async function copyInstall(key: string, text: string) {
  try {
    await navigator.clipboard.writeText(text);
  } catch {
    // A denied or absent clipboard is not worth an error state: the text is
    // still on screen and still selectable.
    return;
  }
  copiedKey.value = key;
  if (copiedTimer) clearTimeout(copiedTimer);
  copiedTimer = setTimeout(() => {
    copiedKey.value = null;
  }, 1600);
}

const temperature = ref(60);
const zip = ref("94110");

/** The selectors, written the way the Swift declarations read. */
function advice(t: number) {
  return t > 70 ? "shorts" : "coat";
}
function city(z: string) {
  return z === "94110" ? "San Francisco" : "Brooklyn";
}

function valuesFor(t: number, z: string): Record<string, string> {
  const a = advice(t);
  const c = city(z);
  const h = `${c}: ${a}`;
  return {
    temperature: `${t}°`,
    zip: z,
    advice: a,
    city: c,
    headline: h,
    AdviceLabel: a,
    Banner: h,
    CityTitle: c,
  };
}

const values = computed(() => valuesFor(temperature.value, zip.value));

/** Nodes that re-ran during the last turn, and those whose value changed. */
const ran = ref<Set<string>>(new Set());
const changed = ref<Set<string>>(new Set());
const turns = ref(0);
const lastSettled = ref(0);
const lastRedrawn = ref(0);
const hasRun = ref(false);

const parentsOf = new Map<string, string[]>();
for (const [from, to] of EDGES) {
  parentsOf.set(to, [...(parentsOf.get(to) ?? []), from]);
}

let clearTimer: ReturnType<typeof setTimeout> | undefined;

/**
 * Runs one turn and records what it touched.
 *
 * A node re-runs only when something it read actually changed, which is why
 * `changed` gates the descent rather than `ran`.
 */
function commit(mutate: () => void) {
  const before = valuesFor(temperature.value, zip.value);
  const writes: string[] = [];
  const t0 = temperature.value;
  const z0 = zip.value;
  mutate();
  if (temperature.value !== t0) writes.push("temperature");
  if (zip.value !== z0) writes.push("zip");

  const after = valuesFor(temperature.value, zip.value);
  const didRun = new Set<string>();
  const didChange = new Set<string>();

  for (const id of writes) {
    didRun.add(id);
    if (before[id] !== after[id]) didChange.add(id);
  }

  // Dependency order, so a node is visited only after everything it reads.
  const ordered = [...NODES].sort((a, b) => a.rank - b.rank);
  for (const node of ordered) {
    if (node.kind === "source") continue;
    const parents = parentsOf.get(node.id) ?? [];
    if (!parents.some((p) => didChange.has(p))) continue;
    didRun.add(node.id);
    if (before[node.id] !== after[node.id]) didChange.add(node.id);
  }

  ran.value = didRun;
  changed.value = didChange;
  turns.value += 1;
  hasRun.value = true;
  lastSettled.value = [...didRun].filter(
    (id) => NODES.find((n) => n.id === id)?.kind === "derived",
  ).length;
  lastRedrawn.value = [...didChange].filter(
    (id) => NODES.find((n) => n.id === id)?.kind === "view",
  ).length;

  if (clearTimer) clearTimeout(clearTimer);
  clearTimer = setTimeout(() => {
    ran.value = new Set();
    changed.value = new Set();
  }, 1400);
}

function warmer() {
  commit(() => {
    temperature.value = Math.min(95, temperature.value + 5);
  });
}
function cooler() {
  commit(() => {
    temperature.value = Math.max(35, temperature.value - 5);
  });
}
function rewrite() {
  // The write that proves the point: same value in, nothing settles.
  commit(() => {
    temperature.value = temperature.value;
  });
}
function toggleZip() {
  commit(() => {
    zip.value = zip.value === "94110" ? "11211" : "94110";
  });
}

const readout = computed(() => {
  if (!hasRun.value) return "waiting for a write";
  const s = lastSettled.value;
  const r = lastRedrawn.value;
  if (s === 0 && r === 0) return "settled nothing · redrew nothing";
  return `settled ${s} value${s === 1 ? "" : "s"} · redrew ${r} view${r === 1 ? "" : "s"}`;
});

function nodeState(id: string) {
  if (changed.value.has(id)) return "changed";
  if (ran.value.has(id)) return "ran";
  return "idle";
}
function edgeState([from, to]: [string, string]) {
  return changed.value.has(from) && ran.value.has(to) ? "live" : "idle";
}
function nodeAt(id: string) {
  return NODES.find((n) => n.id === id)!;
}

/**
 * A small model of a mechanism with a state-gated notification scope.
 *
 * The ordering is the lesson, so the model plays it out in time rather than
 * asserting it: the write settles first, an open watch runs only after that,
 * and the notification leaves the graph last. Each beat also lights the line
 * of the source printed beside the model, so the code is the legend for the
 * diagram. Closing the gate tears the nested watch down, and later writes
 * then settle and stop — the severed arrow is the whole point of the demo.
 */

/** Which beat of a turn the model is currently showing. */
type MechanismPhase = "idle" | "state" | "scope" | "watch" | "effect" | "blocked";

/** How one lane of the model reads during the current beat. */
type LaneState = "idle" | "active" | "done" | "blocked";

/** The line of the printed source that the current beat is running. */
type CodeFocus = "none" | "whenever" | "watch" | "send";

type MechanismEventTone = "setup" | "scope" | "effect" | "quiet";

interface MechanismEvent {
  id: number;
  label: string;
  detail: string;
  tone: MechanismEventTone;
}

/** One scheduled beat of the played-out turn. */
interface MechanismBeat {
  at: number;
  run: () => void;
}

/** A beat that has been scheduled but has not run yet. */
interface PendingBeat {
  timer: ReturnType<typeof setTimeout>;
  run: () => void;
}

const alertsEnabled = ref(true);
const receivedMessages = ref(0);
const sentNotifications = ref(0);
const lastNotification = ref("nothing yet");
const mechanismPhase = ref<MechanismPhase>("idle");
const codeFocus = ref<CodeFocus>("none");
const mechanismReadout = ref("Scope open. The watch is registered and waiting.");
const mechanismEvents = ref<MechanismEvent[]>([
  {
    id: 0,
    label: "Assembly",
    detail: "The gate read true; the watch went live.",
    tone: "setup",
  },
]);

let nextMechanismEventID = 1;
let pendingBeats: PendingBeat[] = [];
let restTimer: ReturnType<typeof setTimeout> | undefined;

function prefersReducedMotion() {
  return window.matchMedia?.("(prefers-reduced-motion: reduce)").matches ?? false;
}

/** Records one visible event and keeps the explanation short enough to scan. */
function recordMechanismEvent(label: string, detail: string, tone: MechanismEventTone) {
  mechanismEvents.value = [
    { id: nextMechanismEventID, label, detail, tone },
    ...mechanismEvents.value,
  ].slice(0, 3);
  nextMechanismEventID += 1;
}

/**
 * Plays one turn beat by beat, then returns the model to rest.
 *
 * A reader who has asked for reduced motion gets every beat at once, which
 * lands on the same final state without the staged reveal.
 */
function playMechanismTurn(beats: MechanismBeat[]) {
  flushMechanismTurn();

  const staged = !prefersReducedMotion();
  for (const beat of beats) {
    if (!staged || beat.at === 0) {
      beat.run();
      continue;
    }
    const timer = setTimeout(() => {
      pendingBeats = pendingBeats.filter((pending) => pending.timer !== timer);
      beat.run();
    }, beat.at);
    pendingBeats.push({ timer, run: beat.run });
  }

  const settled = staged ? beats[beats.length - 1].at : 0;
  restTimer = setTimeout(() => {
    mechanismPhase.value = "idle";
    codeFocus.value = "none";
  }, settled + 2_400);
}

/**
 * Finishes whatever the previous turn had left to do.
 *
 * A second click arriving mid-turn must not drop the notification the first
 * one had already earned, so the outstanding beats run now rather than being
 * cancelled; the incoming turn overwrites the readout a moment later anyway.
 */
function flushMechanismTurn() {
  const outstanding = pendingBeats;
  pendingBeats = [];
  for (const beat of outstanding) {
    clearTimeout(beat.timer);
    beat.run();
  }
  if (restTimer) clearTimeout(restTimer);
  restTimer = undefined;
}

/** Writes the gate. Opening it registers a fresh watch; closing it removes one. */
function toggleAlerts() {
  const next = !alertsEnabled.value;

  playMechanismTurn([
    {
      at: 0,
      run: () => {
        alertsEnabled.value = next;
        mechanismPhase.value = "state";
        codeFocus.value = "none";
        mechanismReadout.value = `alertsEnabled settled to ${next}.`;
      },
    },
    {
      at: 460,
      run: () => {
        mechanismPhase.value = "scope";
        codeFocus.value = "whenever";
        mechanismReadout.value = next
          ? "The scope reopened and registered a fresh watch."
          : "The scope closed and took its watch with it.";
        recordMechanismEvent(
          next ? "Gate rose" : "Gate fell",
          next ? "A fresh scope registered a new watch." : "The scope tore down with its watch.",
          "scope",
        );
      },
    },
  ]);
}

/** Writes message state, then runs the effect only while a watch exists. */
function receiveMessage() {
  const count = receivedMessages.value + 1;
  const message = `Message ${count}`;
  const watching = alertsEnabled.value;

  const beats: MechanismBeat[] = [
    {
      at: 0,
      run: () => {
        receivedMessages.value = count;
        mechanismPhase.value = "state";
        codeFocus.value = "none";
        mechanismReadout.value = `messageCount settled to ${count}.`;
      },
    },
  ];

  if (watching) {
    beats.push(
      {
        at: 460,
        run: () => {
          mechanismPhase.value = "watch";
          codeFocus.value = "watch";
          mechanismReadout.value = "State finished settling, so the watch runs.";
        },
      },
      {
        at: 920,
        run: () => {
          sentNotifications.value += 1;
          lastNotification.value = message;
          mechanismPhase.value = "effect";
          codeFocus.value = "send";
          mechanismReadout.value = `The notifier sent “${message}” outside the graph.`;
          postToast(message, "Sent by NotificationsMechanism.");
          recordMechanismEvent(
            `${message} received`,
            "State settled, then the watch sent one.",
            "effect",
          );
        },
      },
    );
  } else {
    beats.push({
      at: 460,
      run: () => {
        mechanismPhase.value = "blocked";
        codeFocus.value = "none";
        mechanismReadout.value = "No watch is registered, so nothing left the graph.";
        recordMechanismEvent(
          `${message} received`,
          "Settled with no watch, so nothing ran.",
          "quiet",
        );
      },
    });
  }

  playMechanismTurn(beats);
}

/**
 * The notifier the mechanism holds.
 *
 * The demo's whole claim is that this work leaves the graph, so it does: the
 * notification is not another panel inside the model but a real toast pinned
 * to the viewport, outside every box the section draws. The stack is hidden
 * from assistive technology because the readout beside the controls already
 * announces the same send, and hearing it twice would be worse than not
 * seeing it once.
 */
interface Toast {
  id: number;
  title: string;
  body: string;
}

const toasts = ref<Toast[]>([]);

let nextToastID = 1;
let toastTimers: Array<ReturnType<typeof setTimeout>> = [];

/** Posts one notification and takes it back down a few seconds later. */
function postToast(title: string, body: string) {
  const id = nextToastID;
  nextToastID += 1;
  toasts.value = [...toasts.value, { id, title, body }].slice(-3);

  const timer = setTimeout(() => {
    toasts.value = toasts.value.filter((toast) => toast.id !== id);
    toastTimers = toastTimers.filter((pending) => pending !== timer);
  }, 4_400);
  toastTimers.push(timer);
}

/**
 * The printed mechanism, one entry per line.
 *
 * The lines carry their own markup because a beat tints exactly the line it
 * runs, and `nested` marks the two registrations that exist only while the
 * gate is up — fading them is how a closed scope reads as absent rather than
 * merely inactive.
 */
interface SourceLine {
  html: string;
  focus?: CodeFocus;
  nested?: boolean;
}

const SOURCE_LINES: SourceLine[] = [
  {
    html: '<span class="k">struct</span> <span class="t">NotificationsMechanism</span>: <span class="t">Mechanism</span> {',
  },
  { html: '  <span class="k">let</span> notifier: <span class="t">Notifier</span>' },
  { html: " " },
  {
    html: '  <span class="k">func</span> operate(<span class="k">_</span> m: <span class="t">MechanismController</span>) {',
  },
  {
    html: '    m.<span class="v">whenever</span>(<span class="v">alertsEnabledCog</span>) { s <span class="k">in</span>',
    focus: "whenever",
  },
  {
    html: '      s.<span class="v">watch</span>(<span class="v">messageCountCog</span>, initial: .skip) { <span class="k">_</span>, count <span class="k">in</span>',
    focus: "watch",
    nested: true,
  },
  {
    html: '        notifier.send(<span class="s">"Message \\(count)"</span>)',
    focus: "send",
    nested: true,
  },
  { html: "      }", nested: true },
  { html: "    }" },
  { html: "  }" },
  { html: "}" },
];

/** Tints the line the current beat is running, and fades unregistered ones. */
function sourceLineClass(line: SourceLine) {
  return {
    focus: line.focus !== undefined && codeFocus.value === line.focus,
    muted: line.nested === true && !alertsEnabled.value,
  };
}

/**
 * How each lane reads during the current beat.
 *
 * A lane the turn has already passed through stays lit faintly, so a finished
 * turn still shows the path it took rather than resetting to nothing.
 */
function laneState(lane: 1 | 2 | 3): LaneState {
  const phase = mechanismPhase.value;
  if (phase === "idle") return "idle";
  if (lane === 1) return phase === "state" ? "active" : "done";
  if (lane === 2) {
    if (phase === "scope" || phase === "watch") return "active";
    if (phase === "blocked") return "blocked";
    return phase === "effect" ? "done" : "idle";
  }
  return phase === "effect" ? "active" : "idle";
}

/** Whether the connector below a lane is carrying the current turn. */
function linkLive(link: 1 | 2) {
  const phase = mechanismPhase.value;
  if (link === 1) return phase === "scope" || phase === "watch" || phase === "blocked";
  return phase === "effect";
}
/**
 * The Storefront comparison, as a matrix.
 *
 * Every figure is the settled-interaction cut of environment E14 in
 * `docs/swift/impl/perf.md`: the same eleven-phase commerce session, the same
 * script, fixtures, and async service, checked against the same shadow model
 * at every checkpoint. Only the state handling underneath differs, which is
 * what makes them worth putting side by side.
 *
 * Every cell but Cog's carries its ratio to Cog, and two of the four rows go
 * to the hand-cached port. Marking those rows as wins is the point rather than
 * an oversight: the note under the matrix carries what that speed costs to
 * maintain, and a comparison that quietly dropped the runtime that beats Cog
 * would be worth less than no comparison at all.
 */
interface RuntimeColumn {
  id: string;
  name: string;
  legend: string;
}

const RUNTIMES: RuntimeColumn[] = [
  {
    id: "cog",
    name: "Cog",
    legend:
      "This test app has 12 single values, 5 groups of values such as one per product, and 18 values that Cog calculates. One setup process starts everything when the app opens.",
  },
  {
    id: "observable",
    name: "Plain @Observable",
    legend:
      "Uses Apple's built-in @Observable system. It saves no calculated results, so it calculates every result again when the app reads it. This is a simple baseline, not a finished app.",
  },
  {
    id: "observable-cached",
    name: "Cached @Observable",
    legend:
      "Starts with plain @Observable and adds seven handwritten caches. It takes 89 lines across 19 methods to decide when each saved result is out of date.",
  },
  {
    id: "state-graph",
    name: "swift-state-graph",
    legend:
      "Uses swift-state-graph 0.28.0, another state-management library. We added code for product-specific values, loading data in the background, and deleting old data so it could run the same shopping test.",
  },
];

interface MatrixCell {
  value: string;
  unit?: string;
  /** How this runtime compares with Cog. Cog's own cells carry none. */
  delta?: string;
  /** Whether that comparison goes against Cog. */
  beatsCog?: boolean;
}

interface MatrixRow {
  id: string;
  label: string;
  note: string;
  detail: string;
  cells: MatrixCell[];
}

const MATRIX: MatrixRow[] = [
  {
    id: "time",
    label: "time to finish one update",
    note: "How long one shopping update takes.",
    detail:
      "The update changes four pieces of shopping data, then updates a chain of 23 values used to calculate prices. The number shown is the median time across repeated runs. A screen that refreshes 120 times per second has 8.3 milliseconds between frames. One millisecond (ms) equals 1,000 microseconds (µs).",
    cells: [
      { value: "140", unit: "µs" },
      { value: "115", unit: "ms", delta: "820× slower" },
      { value: "59", unit: "µs", delta: "2.4× faster", beatsCog: true },
      { value: "1,569", unit: "µs", delta: "11× slower" },
    ],
  },
  {
    id: "instructions",
    label: "work done by the processor",
    note: "How many basic commands the processor completes.",
    detail:
      "The benchmark records retired CPU instructions: the basic commands completed during the timed update. The number shown is the median count. M means million. This count does not say how long each command took.",
    cells: [
      { value: "3.9", unit: "M" },
      { value: "2,657", unit: "M", delta: "680× more" },
      { value: "1.2", unit: "M", delta: "3.1× fewer", beatsCog: true },
      { value: "40", unit: "M", delta: "10× more" },
    ],
  },
  {
    id: "allocations",
    label: "requests for temporary memory",
    note: "How many temporary memory blocks the update requests.",
    detail:
      "This is the number of malloc calls during the timed update. Each call asks the memory allocator for a new block. These counters cover the whole process, so the test runs only after all background work has stopped.",
    cells: [
      { value: "12" },
      { value: "4,432", delta: "370× more" },
      { value: "74", delta: "6.2× more" },
      { value: "2,602", delta: "220× more" },
    ],
  },
  {
    id: "allocation-bytes",
    label: "temporary memory requested",
    note: "How much temporary memory those requests add up to.",
    detail:
      "This is the total number of bytes requested by the malloc calls, not the most memory held at one time. Each version requested and freed the same number of blocks during the timed update. B, KB, and MB mean bytes, kilobytes, and megabytes.",
    cells: [
      { value: "536", unit: "B" },
      { value: "378", unit: "MB", delta: "700,000× more" },
      { value: "6,035", unit: "B", delta: "11× more" },
      { value: "185", unit: "KB", delta: "345× more" },
    ],
  },
];

/**
 * Places a runtime explanation beside its trigger without letting the matrix's
 * horizontal scroll frame clip it.
 *
 * Column headers move under the sticky row-label column on narrow screens, so
 * a table-relative panel can be partly hidden even while its trigger is in
 * view. Fixed positioning keeps the panel in the viewport; the calculation
 * below chooses the nearest edge and flips upward only when the lower edge
 * would run offscreen.
 */
function positionColumnDetail(event: Event) {
  const trigger = event.currentTarget;
  if (!(trigger instanceof HTMLElement)) return;
  const popover = trigger.nextElementSibling;
  if (!(popover instanceof HTMLElement)) return;

  const margin = 16;
  const gap = 10;
  const triggerRect = trigger.getBoundingClientRect();
  const popoverRect = popover.getBoundingClientRect();
  const idealLeft = triggerRect.left + (triggerRect.width - popoverRect.width) / 2;
  const left = Math.min(
    Math.max(idealLeft, margin),
    window.innerWidth - popoverRect.width - margin,
  );
  const opensAbove = triggerRect.bottom + gap + popoverRect.height > window.innerHeight - margin;
  const top = opensAbove ? triggerRect.top - gap - popoverRect.height : triggerRect.bottom + gap;

  popover.style.left = `${left}px`;
  popover.style.top = `${top}px`;
  popover.style.setProperty("--column-popover-shift", opensAbove ? "-4px" : "4px");
}

/** Runs the demo once when it first scrolls into view, so the page shows its
 *  own point without demanding a click. */
const root = ref<HTMLElement>();
let observer: IntersectionObserver | undefined;

onMounted(() => {
  const reduced = window.matchMedia?.("(prefers-reduced-motion: reduce)").matches;
  if (reduced || !("IntersectionObserver" in window)) return;
  observer = new IntersectionObserver(
    (entries) => {
      for (const entry of entries) {
        if (!entry.isIntersecting || hasRun.value) continue;
        setTimeout(warmer, 500);
        observer?.disconnect();
      }
    },
    { threshold: 0.4 },
  );
  if (root.value) observer.observe(root.value);
});

onBeforeUnmount(() => {
  observer?.disconnect();
  if (clearTimer) clearTimeout(clearTimer);
  for (const beat of pendingBeats) clearTimeout(beat.timer);
  for (const timer of toastTimers) clearTimeout(timer);
  if (restTimer) clearTimeout(restTimer);
  if (copiedTimer) clearTimeout(copiedTimer);
});
</script>

<template>
  <div :class="['cog', { dark: isDark }]">
    <!-- ── Hero ─────────────────────────────────────────────────────── -->
    <header class="hero">
      <p class="eyebrow">State for native mobile UI</p>
      <h1 class="display">
        State that<br />
        <em>feels</em><br />
        simple
      </h1>
      <div class="hero-side">
        <p class="lede">
          Cog keeps your app's state in one graph. Declare each fact once, then derive the rest.
          After a change, Cog settles the values that depend on it and notifies the views that read
          them.
        </p>
        <div class="actions">
          <!--
            The first two actions mirror the consumer path in the Swift docs:
            install the products, then build the working tutorial. Both are
            VitePress routes, so they also work in the local documentation
            server before the separately built DocC archive is merged in.
          -->
          <a class="btn btn-primary" :href="withBase('/swift/installation')"> Getting started </a>
          <a class="btn" :href="withBase('/swift/getting-started')">Learn more</a>
        </div>
        <dl class="facts">
          <div>
            <dt>Swift</dt>
            <dd>
              <a class="release-link" href="https://github.com/skeswa/cog/releases/latest">
                {{ swiftRelease }}
              </a>
            </dd>
          </div>
          <div>
            <dt>Kotlin</dt>
            <dd>designed</dd>
          </div>
          <div>
            <dt>Dependencies</dt>
            <dd>none</dd>
          </div>
        </dl>
      </div>
    </header>

    <!-- ── Install ──────────────────────────────────────────────────────
         A reader who has come this far wants a line to paste, not a second
         summary of the two libraries. So the platform choice costs one row,
         and everything under it is either copyable or a link to the page that
         continues. Xcode's "Add Package Dependencies…" field takes the bare
         repository URL and rejects a manifest snippet, which is why that route
         gets its own line above the `Package.swift` one. -->
    <section class="platforms" aria-labelledby="platforms-title">
      <div class="platforms-head">
        <div>
          <h2 id="platforms-title">Install Cog</h2>
          <p>Swift ships today. Kotlin is designed and not yet built.</p>
        </div>
        <div class="platform-switch" role="group" aria-label="Choose a platform">
          <button
            type="button"
            :aria-pressed="selectedPlatform === 'swift'"
            @click="selectedPlatform = 'swift'"
          >
            Swift <span class="switch-sub">SwiftUI</span>
            <span class="switch-tag shipping">{{ swiftRelease }}</span>
          </button>
          <button
            type="button"
            :aria-pressed="selectedPlatform === 'kotlin'"
            @click="selectedPlatform = 'kotlin'"
          >
            Kotlin <span class="switch-sub">Compose</span>
            <span class="switch-tag planned">Designed</span>
          </button>
        </div>
      </div>

      <div class="install">
        <div class="install-pane" :class="{ hidden: selectedPlatform !== 'swift' }">
          <div class="install-main">
            <p class="install-step">In Xcode, <b>File › Add Package Dependencies…</b> and paste</p>
            <div class="copy-row">
              <code>{{ packageURL }}</code>
              <button type="button" class="copy" @click="copyInstall('url', packageURL)">
                {{ copiedKey === "url" ? "Copied" : "Copy" }}
              </button>
            </div>

            <p class="install-step">Or add it to <code>Package.swift</code></p>
            <div class="copy-row copy-row-block">
              <pre class="code"><code>.package(
  url: <span class="s">"{{ packageURL }}"</span>,
  .upToNextMinor(from: <span class="s">"{{ swiftRelease }}"</span>)
)</code></pre>
              <button type="button" class="copy" @click="copyInstall('manifest', manifestSnippet)">
                {{ copiedKey === "manifest" ? "Copied" : "Copy" }}
              </button>
            </div>

            <p class="install-note">
              Pin to a minor version. Before 1.0 a minor release may carry listed breaking changes;
              a patch release never does.
            </p>
          </div>

          <aside class="install-side">
            <dl class="install-facts">
              <div>
                <dt>Platforms</dt>
                <dd>iOS 17 · macOS 14</dd>
              </div>
              <div>
                <dt>Toolchain</dt>
                <dd>Swift tools 6.2</dd>
              </div>
              <div>
                <dt>Dependencies</dt>
                <dd>none</dd>
              </div>
              <div>
                <dt>Products</dt>
                <dd><code>Cog</code> · <code>CogTesting</code></dd>
              </div>
            </dl>
            <ul class="install-next">
              <li>
                <a :href="withBase('/swift/installation')">
                  Installation <span>Complete Xcode and SwiftPM target setup</span>
                </a>
              </li>
              <li>
                <a :href="withBase('/swift/getting-started')">
                  Getting started <span>Build, run, and test a working screen</span>
                </a>
              </li>
              <li>
                <a :href="withBase('/swift/handbook/')">
                  The handbook <span>How an app should be built with Cog</span>
                </a>
              </li>
              <li>
                <a :href="withBase('/documentation/cog/')" target="_self">
                  API reference <span>Every type, generated from the source</span>
                </a>
              </li>
            </ul>
          </aside>
        </div>

        <div class="install-pane" :class="{ hidden: selectedPlatform !== 'kotlin' }">
          <div class="install-main">
            <p class="install-step">There is nothing to add to a build yet</p>
            <p class="install-empty">
              Cog for Kotlin is designed down to its turn, lifetime, and async semantics, and none
              of it is built. No Gradle coordinate exists yet; this panel will carry one the day it
              does. Until then the design is the deliverable, and it is complete enough to read and
              argue with.
            </p>
            <p class="install-note">
              Watch <a href="https://github.com/skeswa/cog/releases">releases</a> to hear about the
              first Kotlin artifact.
            </p>
          </div>

          <aside class="install-side">
            <dl class="install-facts">
              <div>
                <dt>Target</dt>
                <dd>Jetpack Compose</dd>
              </div>
              <div>
                <dt>State</dt>
                <dd>Compose snapshots</dd>
              </div>
              <div>
                <dt>Status</dt>
                <dd>designed, not built</dd>
              </div>
              <div>
                <dt>Artifact</dt>
                <dd>none yet</dd>
              </div>
            </dl>
            <ul class="install-next">
              <li>
                <a :href="withBase('/kotlin/')">
                  The Kotlin design <span>What is settled and what is open</span>
                </a>
              </li>
              <li>
                <a :href="withBase('/kotlin/example')">
                  A worked example <span>The same weather app, in Kotlin</span>
                </a>
              </li>
              <li>
                <a :href="withBase('/kotlin/flows')">
                  Flow map <span>How Cog and coroutines meet</span>
                </a>
              </li>
            </ul>
          </aside>
        </div>
      </div>
    </section>

    <!-- ── Graph demo ───────────────────────────────────────────────── -->
    <section ref="root" class="panel" aria-labelledby="graph-title">
      <div class="panel-head">
        <h2 id="graph-title">Watch state change</h2>
        <p>
          This eight-node graph shows how an update moves through dependent state. Change a source
          to see which derived values run and which views redraw.
        </p>
      </div>

      <div class="stage-scroll">
        <div class="stage">
          <svg class="graph" viewBox="0 0 100 100" preserveAspectRatio="none" aria-hidden="true">
            <line
              v-for="edge in EDGES"
              :key="edge.join('>')"
              :class="['edge', edgeState(edge)]"
              :x1="nodeAt(edge[0]).x"
              :y1="nodeAt(edge[0]).y"
              :x2="nodeAt(edge[1]).x"
              :y2="nodeAt(edge[1]).y"
              vector-effect="non-scaling-stroke"
            />
          </svg>

          <div
            v-for="node in NODES"
            :key="node.id"
            :class="['node', node.kind, nodeState(node.id)]"
            :style="{ left: `${node.x}%`, top: `${node.y}%` }"
          >
            <span class="node-label">{{ node.label }}</span>
            <span class="node-value">{{ values[node.id] }}</span>
          </div>
        </div>
      </div>

      <div class="controls">
        <div class="buttons">
          <button type="button" @click="cooler">− 5°</button>
          <button type="button" @click="warmer">+ 5°</button>
          <button type="button" @click="rewrite">write the same value</button>
          <button type="button" @click="toggleZip">change zip</button>
        </div>
        <output :class="['readout', { quiet: lastSettled === 0 && lastRedrawn === 0 && hasRun }]">
          {{ readout }}
        </output>
      </div>

      <p class="aside">
        Writing the same value does not rerun a selector. When the temperature crosses 70°,
        <code>advice</code> changes. Cog then reruns <code>headline</code> and redraws two views;
        the third view is unchanged.
      </p>
    </section>

    <!-- ── Code ─────────────────────────────────────────────────────── -->
    <section class="split" aria-labelledby="code-title">
      <div class="split-text">
        <h2 id="code-title">State lives in the runtime</h2>
        <p>
          A Cog declaration identifies a value; the runtime stores it. Your app, each test, and each
          preview can use the same declarations while keeping separate state.
        </p>
        <p>
          <code>adviceCog</code> runs on its first read. It runs again only after the temperature
          value it read changes.
        </p>
        <a class="more" :href="withBase('/swift/')">Read the Swift design →</a>
      </div>
      <pre
        class="code"
      ><code><span class="k">let</span> <span class="v">_temperatureCog</span> = <span class="t">Cog</span>&lt;<span class="t">Int</span>&gt;.<span class="t">Manual</span>(<span class="n">60</span>)
<span class="k">let</span> <span class="v">adviceCog</span> = <span class="t">Cog</span>&lt;<span class="t">String</span>&gt; { c <span class="k">in</span>
  c[<span class="v">_temperatureCog</span>] &gt; <span class="n">70</span> ? <span class="s">"shorts"</span> : <span class="s">"coat"</span>
}

<span class="k">struct</span> <span class="t">AdviceLabel</span>: <span class="t">View</span> {
  <span class="a">@Environment</span>(\.cogs) <span class="k">private var</span> cogs

  <span class="k">var</span> body: <span class="k">some</span> <span class="t">View</span> {
    <span class="k">let</span> advice = cogs[<span class="v">adviceCog</span>]
    <span class="t">Text</span>(advice)
  }
}</code></pre>
    </section>

    <!-- ── Mechanisms ───────────────────────────────────────────────── -->
    <section class="panel mechanism-panel" aria-labelledby="mechanism-title">
      <div class="panel-head">
        <h2 id="mechanism-title">First-class side effects</h2>
        <p>
          Everything above stays inside the graph. A side effect is the work that leaves it —
          posting a notification, writing a file, calling a service. Cog gives that work one home: a
          <strong>mechanism</strong>, registered once when the app assembles. Run a turn below and
          watch it cross the boundary.
        </p>
      </div>

      <div class="mechanism-stage">
        <figure class="mechanism-source">
          <figcaption>
            <span class="mechanism-kicker">The mechanism</span>
            <span class="mechanism-file">NotificationsMechanism.swift</span>
          </figcaption>
          <pre class="code"><code><span
              v-for="(line, index) in SOURCE_LINES"
              :key="index"
              :class="['src-line', sourceLineClass(line)]"
              v-html="line.html"
            /></code></pre>
          <p class="mechanism-source-note">
            <code>Cogs.assemble(mechanisms:)</code> runs <code>operate</code> once, and it is the
            only place that can.
            <template v-if="alertsEnabled">
              The gate reads true, so the body below it is live and its watch is registered.
            </template>
            <template v-else>
              The gate reads false, so the scope is torn down and the faded lines are not registered
              at all.
            </template>
          </p>
        </figure>

        <div class="mechanism-lanes">
          <article :class="['mechanism-lane', `is-${laneState(1)}`]">
            <span class="lane-index" aria-hidden="true">1</span>
            <div class="lane-body">
              <span class="mechanism-kicker">In the graph</span>
              <h3>App state</h3>
              <dl class="lane-values">
                <div>
                  <dt>alertsEnabledCog</dt>
                  <dd :class="{ live: alertsEnabled }">{{ alertsEnabled }}</dd>
                </div>
                <div>
                  <dt>messageCountCog</dt>
                  <dd>{{ receivedMessages }}</dd>
                </div>
              </dl>
            </div>
          </article>

          <div :class="['mechanism-link', { 'is-live': linkLive(1) }]">
            <span class="link-rail" aria-hidden="true"></span>
            <span class="link-caption">the turn settles first</span>
          </div>

          <article :class="['mechanism-lane', `is-${laneState(2)}`]">
            <span class="lane-index" aria-hidden="true">2</span>
            <div class="lane-body">
              <span class="mechanism-kicker">At the boundary</span>
              <h3>NotificationsMechanism</h3>
              <dl class="lane-values">
                <div>
                  <dt>whenever(alertsEnabled)</dt>
                  <dd :class="{ live: alertsEnabled }">
                    {{ alertsEnabled ? "scope open" : "scope closed" }}
                  </dd>
                </div>
                <div>
                  <dt>watch(messageCount)</dt>
                  <dd :class="{ gone: !alertsEnabled }">
                    {{ alertsEnabled ? "registered" : "torn down" }}
                  </dd>
                </div>
              </dl>
            </div>
          </article>

          <div
            :class="['mechanism-link', { 'is-live': linkLive(2), 'is-severed': !alertsEnabled }]"
          >
            <span class="link-rail" aria-hidden="true"></span>
            <span class="link-caption">
              {{ alertsEnabled ? "then the watch runs" : "no watch, no effect" }}
            </span>
          </div>

          <article :class="['mechanism-lane', `is-${laneState(3)}`]">
            <span class="lane-index" aria-hidden="true">3</span>
            <div class="lane-body">
              <span class="mechanism-kicker">Outside the graph</span>
              <h3>Notifier</h3>
              <dl class="lane-values">
                <div>
                  <dt>notifications sent</dt>
                  <dd>{{ sentNotifications }}</dd>
                </div>
                <div>
                  <dt>last</dt>
                  <dd>{{ lastNotification }}</dd>
                </div>
              </dl>
            </div>
          </article>
        </div>

        <div class="mechanism-controls">
          <div class="buttons">
            <button type="button" class="btn-run" @click="receiveMessage">Receive a message</button>
            <button type="button" @click="toggleAlerts">
              Set alertsEnabled = {{ alertsEnabled ? "false" : "true" }}
            </button>
          </div>
          <output class="mechanism-readout" aria-live="polite">{{ mechanismReadout }}</output>
        </div>

        <section class="mechanism-history" aria-label="Recent turns">
          <div class="history-head">
            <span class="mechanism-kicker">Turn log</span>
            <span class="history-hint">newest first</span>
          </div>
          <ol class="mechanism-log">
            <li v-for="event in mechanismEvents" :key="event.id" :class="event.tone">
              <span class="log-label">{{ event.label }}</span>
              <span class="log-detail">{{ event.detail }}</span>
            </li>
          </ol>
        </section>
      </div>

      <p class="aside">
        The gate is ordinary state, so the scope's lifetime is ordinary state too. When
        <code>alertsEnabled</code> settles false the scope tears down and its watch unregisters;
        when it settles true again the body runs from scratch. Nothing survives that cycle, which is
        why a mechanism never unregisters anything by hand.
        <a class="mechanism-more" :href="withBase('/swift/design/mechanisms')">
          Read the Mechanism model →
        </a>
      </p>
    </section>

    <!-- ── Measurements ─────────────────────────────────────────────── -->
    <section class="measures" aria-labelledby="measures-title">
      <div class="split-text measures-text">
        <h2 id="measures-title">
          Minimal overhead
          <sup class="measure-note">
            <a
              class="metric-popover-trigger measure-note-trigger"
              :href="withBase('/swift/impl/perf')"
              aria-label="Open the full benchmark report"
              aria-describedby="measure-note-copy"
              >*</a
            >
            <span id="measure-note-copy" class="metric-popover measure-note-popover" role="tooltip">
              All four versions ran one after another in the same test session on an Apple M5 Pro
              with 48 GB of memory. The computer ran macOS 26.5.1, Xcode 26.6 (17F113), and Swift
              6.3.3. A test tool counted every request for temporary memory. The full benchmark
              report explains the setup, limits, and results.
            </span>
          </sup>
        </h2>
        <p>
          Four versions ran the same 11-step shopping test and produced the same results. Lower is
          better. Handwritten caching wins two rows but makes developers manage saved results by
          hand; Cog records what each calculation reads and updates the right values automatically.
          <a class="measures-more" :href="withBase('/swift/impl/perf')">
            Read the full benchmark report →
          </a>
        </p>
      </div>

      <div class="matrix-scroll">
        <table class="matrix">
          <thead>
            <tr>
              <td class="matrix-corner"></td>
              <th
                v-for="column in RUNTIMES"
                :key="column.id"
                scope="col"
                :class="{ subject: column.id === 'cog' }"
              >
                <span class="matrix-name">{{ column.name }}</span>
                <span class="matrix-kind">
                  <span class="column-detail">
                    <button
                      type="button"
                      class="metric-popover-trigger column-detail-trigger"
                      :aria-label="`Learn more about ${column.name}`"
                      :aria-describedby="`matrix-column-${column.id}`"
                      @mouseenter="positionColumnDetail"
                      @focus="positionColumnDetail"
                    >
                      Learn more
                    </button>
                    <span
                      :id="`matrix-column-${column.id}`"
                      class="metric-popover column-detail-popover"
                      role="tooltip"
                    >
                      {{ column.legend }}
                    </span>
                  </span>
                </span>
              </th>
            </tr>
          </thead>
          <tbody>
            <tr v-for="row in MATRIX" :key="row.label">
              <th scope="row">
                <span class="matrix-measure">{{ row.label }}</span>
                <span class="matrix-note">
                  {{ row.note }}
                  <span class="matrix-detail">
                    <button
                      type="button"
                      class="metric-popover-trigger matrix-detail-trigger"
                      :aria-label="`More about ${row.label}`"
                      :aria-describedby="`matrix-detail-${row.id}`"
                    >
                      …
                    </button>
                    <span
                      :id="`matrix-detail-${row.id}`"
                      class="metric-popover matrix-detail-popover"
                      role="tooltip"
                    >
                      {{ row.detail }}
                    </span>
                  </span>
                </span>
              </th>
              <td
                v-for="(cell, index) in row.cells"
                :key="RUNTIMES[index].id"
                :class="{ subject: RUNTIMES[index].id === 'cog' }"
              >
                <span class="matrix-value">
                  {{ cell.value }}<span v-if="cell.unit" class="unit">{{ cell.unit }}</span>
                </span>
                <span v-if="cell.delta" :class="['matrix-delta', { beats: cell.beatsCog }]">
                  {{ cell.delta }}
                </span>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </section>

    <!-- ── Closing ──────────────────────────────────────────────────────
         The page ended on a data table, which is a stopping point rather than
         an ending. This is the ending: it names what the page has been showing
         evidence of — that the whole thing is written down — and hands the
         reader the two documents that carry it. The install panel at the top
         already points at getting started and the API, so this half of the
         page points at the other half of the docs instead of repeating them. -->
    <section class="closing" aria-labelledby="closing-title">
      <div class="closing-text">
        <h2 id="closing-title">Read the docs</h2>
        <p>
          The handbook shows how to build an app with Cog, using code from the example apps. When
          you want the reasoning behind a rule, the design overview explains the tradeoffs and marks
          any decision that remains open.
        </p>
        <div class="actions">
          <a class="btn btn-primary" :href="withBase('/swift/handbook/')">Read the handbook</a>
          <a class="btn" :href="withBase('/swift/design/exploration')"
            >Browse the design overview</a
          >
        </div>
      </div>
      <ul class="closing-more">
        <li><a :href="withBase('/swift/impl/scenarios')">Promised behavior</a></li>
        <li><a :href="withBase('/swift/impl/perf')">The benchmark report</a></li>
        <li><a :href="withBase('/design')">The shared state model</a></li>
        <li><a :href="withBase('/kotlin/')">Cog for Kotlin</a></li>
        <li><a href="https://github.com/skeswa/cog">Source on GitHub</a></li>
      </ul>
    </section>

    <!-- ── The notifier's output ────────────────────────────────────── -->
    <TransitionGroup name="toast" tag="div" class="toast-stack" aria-hidden="true">
      <article v-for="toast in toasts" :key="toast.id" class="toast">
        <span class="toast-icon">
          <svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.3">
            <path d="M4 6.6a4 4 0 0 1 8 0c0 2.4.6 3.5 1.2 4.1H2.8C3.4 10.1 4 9 4 6.6Z" />
            <path d="M6.6 12.9a1.6 1.6 0 0 0 2.8 0" />
          </svg>
        </span>
        <div class="toast-body">
          <p class="toast-meta"><span>Cog</span><span>now</span></p>
          <p class="toast-title">{{ toast.title }}</p>
          <p class="toast-detail">{{ toast.body }}</p>
        </div>
      </article>
    </TransitionGroup>
  </div>
</template>

<style scoped>
/* ── Tokens ─────────────────────────────────────────────────────────
   A precision-instrument palette: near-white or near-black ground,
   hairline rules, and one electric blue doing all the signalling. The
   neutrals are cool on purpose — a saturated blue fights warm paper.
   Both themes are defined explicitly so neither inherits a default. */
.cog {
  --paper: #fbfbfc;
  --paper-2: #f1f1f5;
  --ink: #0d0d12;
  --ink-2: #55555f;
  --ink-3: #6e6e78;
  --rule: #e4e4ea;
  --rule-2: #cdcdd7;
  --accent: #1a1aff;
  --accent-strong: #1212cc;
  --accent-wash: rgba(26, 26, 255, 0.09);
  --live: #087f4f;
  --code-bg: #f2f2f7;

  --display: var(--cog-font-display);
  --mono: var(--cog-font-mono);

  color: var(--ink);
  font-family: var(--mono);
  font-size: 15px;
  line-height: 1.65;
  max-width: 1180px;
  margin: 0 auto;
  padding: 0 24px;
  font-feature-settings: "kern", "liga";
}

.cog.dark {
  /* `#1a1aff` is only 2.5:1 on this ground, so the dark palette lifts the
     accent rather than reusing the light one and calling it a theme. */
  --paper: #0b0b10;
  --paper-2: #14141b;
  --ink: #eeeef4;
  --ink-2: #9e9eaa;
  --ink-3: #7a7a88;
  --rule: #23232e;
  --rule-2: #33333f;
  --accent: #6f78ff;
  --accent-strong: #9aa2ff;
  --accent-wash: rgba(111, 120, 255, 0.16);
  --live: #34d399;
  --code-bg: #07070b;
}

/* The page paints its own ground rather than borrowing the theme's. */
.cog::before {
  content: "";
  position: fixed;
  inset: 0;
  z-index: -1;
  background:
    linear-gradient(var(--rule) 1px, transparent 1px) 0 0 / 100% 88px,
    linear-gradient(90deg, var(--rule) 1px, transparent 1px) 0 0 / 88px 100%,
    var(--paper);
  opacity: 1;
  -webkit-mask-image: radial-gradient(ellipse 90% 60% at 50% 0%, #000 0%, transparent 75%);
  mask-image: radial-gradient(ellipse 90% 60% at 50% 0%, #000 0%, transparent 75%);
  pointer-events: none;
}

.cog :where(h1, h2, h3) {
  font-weight: 400;
  letter-spacing: -0.01em;
}

/* ── Hero ───────────────────────────────────────────────────────── */
.hero {
  display: grid;
  grid-template-columns: minmax(0, 1fr) minmax(0, 1fr);
  gap: 0 56px;
  align-items: end;
  padding: 96px 0 72px;
}

.eyebrow {
  grid-column: 1 / -1;
  margin: 0 0 28px;
  font-size: 12px;
  letter-spacing: 0.18em;
  text-transform: uppercase;
  color: var(--ink-2);
}

.display {
  font-family: var(--display);
  font-size: clamp(66px, 13vw, 148px);
  line-height: 0.86;
  letter-spacing: -0.028em;
  margin: 0;
}

.display em {
  font-style: italic;
}

.hero-side {
  padding-bottom: 6px;
}

.lede {
  margin: 0 0 30px;
  color: var(--ink-2);
  font-size: 14.5px;
  max-width: 46ch;
}

.actions {
  display: flex;
  flex-wrap: wrap;
  gap: 10px;
  margin-bottom: 36px;
}

.btn {
  display: inline-block;
  padding: 10px 18px;
  border: 1px solid var(--rule-2);
  color: var(--ink);
  text-decoration: none;
  font-size: 13px;
  letter-spacing: 0.02em;
  background: transparent;
  transition:
    background-color 0.16s ease,
    border-color 0.16s ease,
    color 0.16s ease;
}

.btn:hover {
  border-color: var(--accent);
  color: var(--accent);
}

/* White on `#1a1aff` measures 8:1, so the primary action can be the brand
   colour itself rather than a neutral that merely sits beside it. */
.btn-primary {
  background: var(--accent);
  border-color: var(--accent);
  color: #fff;
}

.btn-primary:hover {
  background: var(--accent-strong);
  border-color: var(--accent-strong);
  color: #fff;
}

.facts {
  display: flex;
  flex-wrap: wrap;
  gap: 0 32px;
  margin: 0;
  padding-top: 20px;
  border-top: 1px solid var(--rule);
}

.facts dt {
  font-size: 10.5px;
  letter-spacing: 0.14em;
  text-transform: uppercase;
  color: var(--ink-3);
}

.facts dd {
  margin: 2px 0 0;
  font-size: 13px;
}

.release-link {
  color: var(--ink);
  text-decoration-color: var(--rule-2);
  text-underline-offset: 3px;
  transition:
    color 0.16s ease,
    text-decoration-color 0.16s ease;
}

.release-link:hover {
  color: var(--accent);
  text-decoration-color: currentColor;
}

/* ── Install ────────────────────────────────────────────────────────
   The heading and the platform switch share one row, so choosing a platform
   costs a line rather than two card-sized paragraphs. Below it the panel runs
   two columns: what to paste on the left, what the reader needs to know and
   where to go next on the right. Both columns are short by construction —
   anything longer belongs on the page the right column links to. */
.platforms {
  margin-top: 88px;
}

.platforms-head {
  display: flex;
  align-items: end;
  justify-content: space-between;
  gap: 24px;
  flex-wrap: wrap;
}

.platforms-head > div:first-child p {
  margin: 0;
  color: var(--ink-2);
  font-size: 13.5px;
}

/* A segmented control, not a pair of cards: the two options sit in one
   hairline box so the choice reads as one control with one answer. */
.platform-switch {
  display: flex;
  flex: none;
  border: 1px solid var(--rule);
  background: color-mix(in srgb, var(--paper-2) 70%, transparent);
}

.platform-switch button {
  appearance: none;
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 10px 16px;
  border: 0;
  background: none;
  color: var(--ink-2);
  font: inherit;
  font-size: 13px;
  cursor: pointer;
  transition:
    color 0.16s ease,
    background-color 0.16s ease;
}

.platform-switch button + button {
  border-left: 1px solid var(--rule);
}

.platform-switch button:hover {
  color: var(--ink);
}

.platform-switch button[aria-pressed="true"] {
  color: var(--ink);
  background: var(--accent-wash);
  box-shadow: inset 0 2px 0 var(--accent);
}

.platform-switch button:focus-visible {
  outline: 2px solid var(--accent);
  outline-offset: -2px;
}

.switch-sub {
  color: var(--ink-3);
  font-size: 11.5px;
}

.switch-tag {
  font-size: 10px;
  letter-spacing: 0.1em;
  text-transform: uppercase;
  padding: 2px 6px;
  border: 1px solid currentColor;
}

.switch-tag.shipping {
  color: var(--live);
}
.switch-tag.planned {
  color: var(--ink-3);
}

/* Both platforms are laid out in the same grid cell, so the panel is always
   as tall as the taller of them and switching moves nothing below it. The
   inactive pane keeps its box — `visibility` rather than `display` — which is
   what donates the height, and which also takes it out of the tab order and
   the accessibility tree without a second attribute saying so. */
.install {
  display: grid;
  margin-top: 20px;
  border: 1px solid var(--rule);
  background: var(--paper);
}

.install-pane {
  grid-area: 1 / 1;
  display: grid;
  grid-template-columns: minmax(0, 1.4fr) minmax(0, 1fr);
  align-content: start;
  gap: 40px;
  padding: 26px 28px;
}

.install-pane.hidden {
  visibility: hidden;
}

.install-step {
  margin: 0 0 8px;
  color: var(--ink-3);
  font-size: 12px;
}

.install-step b {
  color: var(--ink-2);
  font-weight: 500;
}

.install-step:not(:first-child) {
  margin-top: 18px;
}

/* The copy button overlays the top-right corner of whatever it copies, so a
   one-line URL and a four-line manifest get the same affordance in the same
   place without either growing a header row. */
.copy-row {
  position: relative;
}

.copy-row > code {
  display: block;
  padding: 11px 78px 11px 14px;
  border: 1px solid var(--rule);
  background: var(--code-bg);
  color: var(--ink);
  font-size: 12.5px;
  overflow-x: auto;
  white-space: nowrap;
}

.copy-row-block .code {
  padding: 16px 78px 16px 18px;
}

.copy {
  position: absolute;
  top: 6px;
  right: 6px;
  appearance: none;
  padding: 4px 10px;
  border: 1px solid var(--rule-2);
  background: var(--paper);
  color: var(--ink-2);
  font: inherit;
  font-size: 10.5px;
  letter-spacing: 0.08em;
  text-transform: uppercase;
  cursor: pointer;
  transition:
    color 0.16s ease,
    border-color 0.16s ease;
}

.copy-row:hover .copy,
.copy:focus-visible {
  color: var(--accent);
  border-color: var(--accent);
}

.install-note {
  margin: 14px 0 0;
  color: var(--ink-3);
  font-size: 12px;
  max-width: 58ch;
}

.install-empty {
  margin: 0;
  color: var(--ink-2);
  font-size: 13px;
  max-width: 58ch;
}

/* Facts a reader would otherwise have to open the manifest to learn. Four
   rows, no prose: the point is that they can be checked at a glance against
   the project they are about to add this to. */
.install-facts {
  margin: 0;
  border-top: 1px solid var(--rule);
}

.install-facts > div {
  display: flex;
  justify-content: space-between;
  gap: 16px;
  padding: 7px 0;
  border-bottom: 1px solid var(--rule);
}

.install-facts dt {
  color: var(--ink-3);
  font-size: 11.5px;
}

.install-facts dd {
  margin: 0;
  color: var(--ink);
  font-size: 11.5px;
  text-align: right;
}

.install-facts dd code {
  font-size: 1em;
}

.install-next {
  list-style: none;
  margin: 18px 0 0;
  padding: 0;
}

.install-next a {
  display: block;
  padding: 7px 0;
  color: var(--accent);
  font-size: 12.5px;
  text-decoration: none;
}

.install-next a span {
  display: block;
  color: var(--ink-3);
  font-size: 11.5px;
}

.install-next a:hover {
  color: var(--accent-strong);
}

.install-next a:hover span {
  color: var(--ink-2);
}

/* ── Panels ─────────────────────────────────────────────────────── */
.panel {
  margin-top: 88px;
  border: 1px solid var(--rule);
  background: color-mix(in srgb, var(--paper-2) 70%, transparent);
  padding: 34px;
}

/* These are section headings on a landing page, not the second-level headings
   of an article, so the default theme's rule above every `h2` has to come off.
   Any new section here needs to join this list or it grows a stray separator. */
.panel-head h2,
.split-text h2,
.platforms h2,
.closing h2 {
  font-family: var(--display);
  font-size: 34px;
  margin: 0 0 8px;
  padding-top: 0;
  border-top: 0;
}

.panel-head p {
  margin: 0 0 28px;
  color: var(--ink-2);
  font-size: 13.5px;
}

/* ── Graph ──────────────────────────────────────────────────────── */
/* The node positions are percentages of the stage, so below a certain width
   the boxes would spill past its edges and collide. Rather than reflow the
   graph into something that no longer reads as a graph, the diagram keeps a
   fixed minimum canvas and scrolls inside its own container — the same
   treatment a wide table gets. */
.stage-scroll {
  overflow-x: auto;
  overscroll-behavior-x: contain;
}

.stage {
  position: relative;
  height: 300px;
  min-width: 620px;
  border: 1px dashed var(--rule-2);
  background: color-mix(in srgb, var(--paper) 60%, transparent);
}

.graph {
  position: absolute;
  inset: 0;
  width: 100%;
  height: 100%;
  overflow: visible;
}

.edge {
  stroke: var(--rule-2);
  stroke-width: 1;
  transition: stroke 0.3s ease;
}

.edge.live {
  stroke: var(--accent);
  stroke-width: 1.6;
}

.node {
  position: absolute;
  transform: translate(-50%, -50%);
  display: flex;
  flex-direction: column;
  gap: 1px;
  padding: 6px 10px;
  border: 1px solid var(--rule-2);
  background: var(--paper);
  white-space: nowrap;
  transition:
    border-color 0.25s ease,
    box-shadow 0.25s ease,
    transform 0.25s ease;
}

.node-label {
  font-size: 10.5px;
  letter-spacing: 0.04em;
  color: var(--ink-2);
}

.node-value {
  font-size: 12px;
  font-weight: 500;
  color: var(--ink);
}

.node.source {
  border-left: 3px solid var(--ink-3);
}

.node.view {
  border-style: dashed;
}

.node.ran {
  border-color: var(--accent);
}

.node.changed {
  border-color: var(--accent);
  box-shadow:
    0 0 0 3px var(--accent-wash),
    0 2px 12px -4px var(--accent);
  transform: translate(-50%, -50%) scale(1.045);
}

@media (prefers-reduced-motion: reduce) {
  .node,
  .edge {
    transition: none;
  }
  .node.changed {
    transform: translate(-50%, -50%);
  }
}

/* ── Controls ───────────────────────────────────────────────────── */
.controls {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  justify-content: space-between;
  gap: 14px;
  margin-top: 20px;
}

.buttons {
  display: flex;
  flex-wrap: wrap;
  gap: 8px;
}

.buttons button {
  font-family: var(--mono);
  font-size: 12px;
  padding: 7px 13px;
  border: 1px solid var(--rule-2);
  background: var(--paper);
  color: var(--ink);
  cursor: pointer;
  transition:
    border-color 0.16s ease,
    color 0.16s ease;
}

.buttons button:hover {
  border-color: var(--accent);
  color: var(--accent);
}

.readout {
  font-size: 12.5px;
  letter-spacing: 0.04em;
  color: var(--accent);
  border-bottom: 1px solid var(--accent);
  padding-bottom: 2px;
}

.readout.quiet {
  color: var(--live);
  border-color: var(--live);
}

.aside {
  margin: 22px 0 0;
  padding-top: 18px;
  border-top: 1px solid var(--rule);
  font-size: 13px;
  color: var(--ink-2);
  max-width: 72ch;
}

.aside strong {
  color: var(--ink);
  font-weight: 500;
}

/* ── Mechanisms ───────────────────────────────────────────────────
   The section pairs one source listing with a three-lane model of the
   runtime, because the hard part of the effect story is ordering and a
   static picture cannot show ordering. A turn lights lane one, then the
   lane-two registration that ran, then the lane-three service — and the
   same beats highlight the line of the listing that is running, so the
   code doubles as the diagram's legend. Closing the gate fades the lines
   that are no longer registered and severs the arrow out of the graph. */
.mechanism-panel .panel-head p {
  max-width: 76ch;
}

.mechanism-stage {
  display: grid;
  grid-template-columns: minmax(0, 1.02fr) minmax(0, 0.98fr);
  grid-template-areas:
    "source lanes"
    "controls lanes"
    "log lanes";
  grid-template-rows: auto auto 1fr;
  gap: 0 22px;
  align-items: start;
}

.mechanism-source {
  grid-area: source;
}

.mechanism-lanes {
  grid-area: lanes;
}

.mechanism-controls {
  grid-area: controls;
}

.mechanism-history {
  grid-area: log;
}

.mechanism-kicker {
  color: var(--ink-3);
  font-size: 10px;
  letter-spacing: 0.15em;
  text-transform: uppercase;
}

/* ── The listing ────────────────────────────────────────────────── */
.mechanism-source {
  display: flex;
  flex-direction: column;
  margin: 0;
  border: 1px solid var(--rule-2);
  background: var(--code-bg);
}

.mechanism-source figcaption {
  display: flex;
  flex-wrap: wrap;
  align-items: baseline;
  justify-content: space-between;
  gap: 6px 16px;
  padding: 12px 16px;
  border-bottom: 1px solid var(--rule);
}

.mechanism-file {
  color: var(--ink-2);
  font-size: 11.5px;
}

.mechanism-source .code {
  padding: 18px 16px;
  border: 0;
  font-size: 12px;
  line-height: 1.75;
}

/* Each line is its own block so a beat can tint exactly the code it runs.
   The padding is mirrored by a negative margin, so the tint bleeds to the
   edge of the listing without indenting the code away from it. */
.src-line {
  display: block;
  margin: 0 -16px;
  padding: 0 16px;
  border-left: 2px solid transparent;
  transition:
    background-color 0.22s ease,
    border-color 0.22s ease,
    opacity 0.22s ease;
}

.src-line.focus {
  background: var(--accent-wash);
  border-left-color: var(--accent);
}

.src-line.muted {
  opacity: 0.34;
}

.mechanism-source :deep(.k) {
  color: var(--accent);
}

.mechanism-source :deep(.t) {
  color: var(--ink);
  font-weight: 700;
}

.mechanism-source :deep(.v) {
  color: var(--live);
}

.mechanism-source :deep(.s) {
  color: var(--ink-2);
}

.mechanism-source-note {
  margin: 0;
  padding: 12px 16px;
  border-top: 1px solid var(--rule);
  color: var(--ink-2);
  font-size: 11.5px;
  line-height: 1.7;
}

.mechanism-panel .mechanism-source-note code {
  color: var(--ink);
  font-size: 1em;
  background: none;
  padding: 0;
}

/* ── The three lanes ────────────────────────────────────────────── */
.mechanism-lanes {
  display: grid;
}

.mechanism-lane {
  display: grid;
  grid-template-columns: 22px minmax(0, 1fr);
  gap: 16px;
  padding: 20px 18px;
  border: 1px solid var(--rule-2);
  background: var(--paper);
  transition:
    border-color 0.25s ease,
    box-shadow 0.25s ease,
    background-color 0.25s ease;
}

.mechanism-lane.is-done {
  border-color: color-mix(in srgb, var(--accent) 45%, var(--rule-2));
}

.mechanism-lane.is-active {
  border-color: var(--accent);
  box-shadow: 0 0 0 3px var(--accent-wash);
}

/* A turn that reaches a closed scope has to look like it arrived and stopped,
   not like nothing happened, so the lane darkens as it dashes. */
.mechanism-lane.is-blocked {
  border-style: dashed;
  border-color: var(--ink-3);
}

.mechanism-lane.is-blocked .lane-index {
  border-color: var(--ink-3);
  color: var(--ink-2);
}

.lane-index {
  align-self: start;
  display: grid;
  place-items: center;
  width: 22px;
  height: 22px;
  border: 1px solid var(--rule-2);
  border-radius: 50%;
  color: var(--ink-3);
  font-size: 11px;
  transition:
    border-color 0.25s ease,
    background-color 0.25s ease,
    color 0.25s ease;
}

.mechanism-lane.is-active .lane-index {
  border-color: var(--accent);
  background: var(--accent);
  color: #fff;
}

.mechanism-lane.is-done .lane-index {
  border-color: var(--accent);
  color: var(--accent);
}

.cog.dark .mechanism-lane.is-active .lane-index {
  color: var(--paper);
}

.lane-body h3 {
  margin: 4px 0 12px;
  padding: 0;
  border: 0;
  font-family: var(--display);
  font-size: 23px;
  line-height: 1.15;
}

.lane-values {
  margin: 0;
}

.lane-values div {
  display: grid;
  grid-template-columns: minmax(0, 1fr) auto;
  gap: 14px;
  padding: 7px 0;
  border-top: 1px solid var(--rule);
}

.lane-values dt {
  color: var(--ink-2);
  font-size: 11.5px;
  overflow-wrap: anywhere;
}

.lane-values dd {
  margin: 0;
  color: var(--ink);
  font-size: 11.5px;
  text-align: right;
  overflow-wrap: anywhere;
  transition: color 0.25s ease;
}

.lane-values dd.live {
  color: var(--live);
}

.lane-values dd.gone {
  color: var(--ink-3);
  text-decoration: line-through;
}

/* ── The connectors ─────────────────────────────────────────────── */
.mechanism-link {
  display: grid;
  grid-template-columns: 22px minmax(0, 1fr);
  gap: 16px;
  align-items: center;
  padding: 12px 18px;
}

.link-rail {
  position: relative;
  justify-self: center;
  width: 1px;
  height: 42px;
  background: var(--rule-2);
  transition: background-color 0.25s ease;
}

.link-rail::after {
  content: "";
  position: absolute;
  bottom: 0;
  left: 50%;
  width: 6px;
  height: 6px;
  border-right: 1px solid var(--rule-2);
  border-bottom: 1px solid var(--rule-2);
  transform: translate(-50%, 1px) rotate(45deg);
  transition: border-color 0.25s ease;
}

.link-caption {
  color: var(--ink-3);
  font-size: 10px;
  letter-spacing: 0.13em;
  text-transform: uppercase;
  transition: color 0.25s ease;
}

.mechanism-link.is-live .link-rail,
.mechanism-link.is-live .link-rail::after {
  background: var(--accent);
  border-color: var(--accent);
}

.mechanism-link.is-live .link-caption {
  color: var(--accent);
}

/* A closed gate does not merely quiet the path out of the graph; it removes
   it. The dashed rail says so at rest, before anyone presses anything. */
.mechanism-link.is-severed .link-rail {
  background: linear-gradient(var(--rule-2) 50%, transparent 0) 0 0 / 1px 6px repeat-y;
}

.mechanism-link.is-severed .link-rail::after {
  opacity: 0.4;
}

/* ── Controls, readout, and log ─────────────────────────────────── */
.mechanism-controls {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 12px 20px;
  margin-top: 22px;
}

.buttons button.btn-run {
  border-color: var(--accent);
  background: var(--accent);
  color: #fff;
}

.buttons button.btn-run:hover {
  border-color: var(--accent-strong);
  background: var(--accent-strong);
  color: #fff;
}

.cog.dark .buttons button.btn-run,
.cog.dark .buttons button.btn-run:hover {
  color: var(--paper);
}

.mechanism-readout {
  flex: 1 1 260px;
  color: var(--ink-2);
  font-size: 12.5px;
}

.mechanism-readout::before {
  content: "→ ";
  color: var(--accent);
}

.mechanism-history {
  margin-top: 24px;
}

.history-head {
  display: flex;
  align-items: baseline;
  justify-content: space-between;
  gap: 16px;
  padding-bottom: 9px;
}

.history-hint {
  color: var(--ink-3);
  font-size: 10.5px;
}

/* The log reserves its full height from the start, so filling it in never
   shifts the listing or the model beside it. */
.mechanism-log {
  min-height: 168px;
  margin: 0;
  padding: 0;
  border-top: 1px solid var(--rule);
  list-style: none;
}

.mechanism-log li {
  display: grid;
  grid-template-columns: minmax(0, 12em) minmax(0, 1fr);
  gap: 8px 18px;
  padding: 11px 0 11px 16px;
  border-bottom: 1px solid var(--rule);
  position: relative;
}

.mechanism-log li::before {
  content: "";
  position: absolute;
  top: 17px;
  left: 0;
  width: 6px;
  height: 6px;
  border-radius: 50%;
  background: var(--rule-2);
}

.mechanism-log li.scope::before {
  background: var(--accent);
}

.mechanism-log li.effect::before {
  background: var(--live);
}

.log-label {
  color: var(--ink);
  font-size: 12px;
}

.log-detail {
  color: var(--ink-2);
  font-size: 12px;
  line-height: 1.55;
}

.mechanism-panel .aside {
  max-width: 88ch;
}

.mechanism-more {
  display: inline-block;
  margin-left: 8px;
  color: var(--accent);
  text-decoration: none;
  border-bottom: 1px solid currentColor;
}

@media (prefers-reduced-motion: reduce) {
  .mechanism-lane,
  .lane-index,
  .lane-values dd,
  .src-line,
  .link-rail,
  .link-rail::after,
  .link-caption {
    transition: none;
  }
}

/* ── Code ───────────────────────────────────────────────────────── */
.split {
  display: grid;
  grid-template-columns: minmax(0, 0.85fr) minmax(0, 1.15fr);
  gap: 48px;
  align-items: start;
  margin-top: 88px;
}

.split-text p {
  color: var(--ink-2);
  font-size: 13.5px;
  margin: 0 0 14px;
}

.more {
  font-size: 13px;
  color: var(--accent);
  text-decoration: none;
  border-bottom: 1px solid currentColor;
}

.code {
  margin: 0;
  padding: 24px;
  background: var(--code-bg);
  border: 1px solid var(--rule);
  overflow-x: auto;
  font-size: 12.5px;
  line-height: 1.85;
  tab-size: 2;
}

.code code {
  font-family: var(--mono);
  color: var(--ink);
}

.code .k {
  color: var(--accent);
}
.code .t {
  color: var(--ink);
  font-weight: 700;
}
.code .v {
  color: var(--live);
}
.code .s {
  color: var(--ink-2);
}
.code .n {
  color: var(--ink-2);
  font-weight: 500;
}
.code .a {
  color: var(--ink-3);
}

/* ── Measurements ─────────────────────────────────────────────────
   A comparison matrix in the page's own idiom: hairline rules, mono labels,
   and the display face carrying the numbers. Cog holds the first column and
   the only tinted one, so a reader knows which runtime the page belongs to
   without the layout arguing for it. Two rows go against Cog, and those cells
   are marked rather than muted. */
.measures {
  margin-top: 88px;
}

.measures-text {
  max-width: 82ch;
}

/* Five columns will not fold into a phone, and reflowing them into stacked
   cards stops being a matrix. It scrolls inside its own container instead —
   the treatment the graph and the code listings already use. */
.matrix-scroll {
  margin-top: 30px;
  overflow-x: auto;
  overscroll-behavior-x: contain;
  border: 1px solid var(--rule);
}

/* Fixed layout, because content sizing gave Cog the narrowest column: its
   figures are the shortest, which is the whole point and no reason to squeeze
   it. Equal columns keep the comparison from arguing by width. */
.matrix {
  /* VitePress's base stylesheet makes every table a scrolling block, which
     detaches `table-layout` from the anonymous table it then generates. The
     scrolling belongs to the wrapper here, so the element goes back to being
     a table. */
  display: table;
  overflow: visible;
  margin: 0;
  width: 100%;
  min-width: 940px;
  table-layout: fixed;
  border-collapse: collapse;
  background: var(--paper);
}

/* The base stylesheet paints table cells and zebra-stripes rows from the
   default theme's palette, which does not track this page's tokens in either
   appearance. The matrix clears both and draws only the rules it wants. */
.matrix th,
.matrix td {
  padding: 16px 18px;
  border: 0;
  background: transparent;
  text-align: right;
  vertical-align: top;
  font-weight: 400;
}

.matrix tbody tr {
  background: transparent;
}

.matrix thead th {
  position: relative;
  border-bottom: 1px solid var(--rule-2);
}

.matrix thead {
  background: color-mix(in srgb, var(--paper-2) 72%, var(--paper));
}

.matrix tbody tr + tr th,
.matrix tbody tr + tr td {
  border-top: 1px solid var(--rule);
}

.matrix-corner {
  width: 26%;
}

/* The measure names stay put while the runtimes scroll under them, which is
   the only thing that keeps the matrix readable once it is wider than the
   screen. Their backgrounds have to be opaque for the same reason. */
.matrix .matrix-corner,
.matrix tbody th {
  position: sticky;
  left: 0;
  z-index: 1;
  border-right: 1px solid var(--rule);
}

.matrix thead .matrix-corner {
  background: color-mix(in srgb, var(--paper-2) 72%, var(--paper));
}

.matrix tbody th {
  background: var(--paper);
}

.matrix-name,
.matrix-kind,
.matrix-measure,
.matrix-note,
.matrix-value,
.matrix-delta {
  display: block;
}

.matrix-name {
  color: var(--ink);
  font-size: 12.5px;
  line-height: 1.2;
}

.matrix-kind {
  margin-top: 2px;
  line-height: 1.1;
}

/* Cog's column. The wash is the same one the accent uses everywhere else, so
   the emphasis reads as identity rather than as a claim about the numbers. */
.matrix .subject {
  background: var(--accent-wash);
}

.matrix thead th.subject .matrix-name {
  color: var(--accent);
}

/* The row header is the only left-aligned cell, which is what tells a reader
   where each row begins once the matrix scrolls sideways. */
.matrix tbody th {
  text-align: left;
}

.matrix-measure {
  color: var(--ink);
  font-size: 12.5px;
}

.matrix-note {
  position: relative;
  max-width: 34ch;
  margin-top: 5px;
  color: var(--ink-2);
  font-size: 11px;
  line-height: 1.55;
}

/* The short sentence stays readable at a glance. The ellipsis carries the
   benchmark vocabulary for readers who want to inspect the exact measure. */
.matrix-detail {
  display: inline;
}

.metric-popover-trigger {
  appearance: none;
  padding: 0;
  border: 0;
  color: var(--ink-3);
  background: transparent;
  font-family: var(--mono);
  line-height: 1;
  text-decoration: none;
  cursor: help;
}

.metric-popover-trigger:hover {
  color: var(--accent);
}

.metric-popover-trigger:focus-visible {
  outline: 2px solid var(--accent);
  outline-offset: 2px;
  color: var(--accent);
}

.matrix-detail-trigger {
  margin: 0 0 0 3px;
  padding: 0 2px 1px;
  font-size: 13px;
  vertical-align: baseline;
}

.column-detail {
  display: inline-block;
}

.column-detail-trigger {
  padding-bottom: 1px;
  border-bottom: 1px solid currentColor;
  font-size: 10.5px;
  cursor: pointer;
}

/* The heading asterisk, column links, and row ellipses share this panel. Their
   anchors differ so each panel stays visible around the scrolling matrix. */
.metric-popover {
  z-index: 5;
  width: min(320px, calc(100vw - 88px));
  padding: 13px 15px;
  border: 1px solid var(--rule-2);
  border-left: 2px solid var(--accent);
  color: var(--ink-2);
  background: var(--paper);
  box-shadow: 0 14px 34px rgb(0 0 0 / 10%);
  font-family: var(--mono);
  font-size: 10.5px;
  font-weight: 400;
  line-height: 1.65;
  text-align: left;
  opacity: 0;
  visibility: hidden;
  pointer-events: none;
  transition:
    opacity 0.16s ease,
    visibility 0.16s ease,
    transform 0.16s ease;
}

/* Header notes use viewport coordinates set when their trigger is hovered or
   focused. Fixed positioning lets them escape the matrix's scrolling frame. */
.column-detail-popover {
  --column-popover-shift: 4px;

  position: fixed;
  top: 0;
  left: 0;
  transform: translateY(var(--column-popover-shift));
}

.column-detail:hover .column-detail-popover,
.column-detail:focus-within .column-detail-popover {
  opacity: 1;
  visibility: visible;
  transform: translateY(0);
}

.matrix thead th:hover,
.matrix thead th:focus-within {
  z-index: 4;
}

/* The note is anchored to the whole blurb instead of the final glyph. That
   keeps its left edge inside the sticky column on narrow screens, where the
   matrix itself scrolls sideways. */
.matrix-detail-popover {
  --matrix-popover-shift: 4px;

  position: absolute;
  top: calc(100% + 9px);
  left: 0;
  transform: translateY(var(--matrix-popover-shift));
}

/* The last two rows open upward so their notes stay inside the matrix's
   scrolling frame instead of being clipped at its bottom edge. */
.matrix tbody tr:nth-last-child(-n + 2) .matrix-detail-popover {
  --matrix-popover-shift: -4px;

  top: auto;
  bottom: calc(100% + 9px);
}

.matrix-detail:hover .matrix-detail-popover,
.matrix-detail:focus-within .matrix-detail-popover {
  opacity: 1;
  visibility: visible;
  transform: translateY(0);
}

/* A sticky header normally shares one layer with the other row headers. Lift
   the active one so its note can cross those rows without being painted over. */
.matrix tbody th:hover,
.matrix tbody th:focus-within {
  z-index: 4;
}

.matrix-value {
  font-family: var(--display);
  font-size: 31px;
  line-height: 1.05;
  color: var(--ink);
}

.matrix td.subject .matrix-value {
  color: var(--accent);
}

.matrix-value .unit {
  font-size: 15px;
  color: var(--ink-2);
  margin-left: 3px;
}

.matrix-delta {
  margin-top: 6px;
  color: var(--ink-3);
  font-size: 10.5px;
  letter-spacing: 0.02em;
}

.matrix-delta.beats {
  color: var(--live);
}

.matrix tbody tr:hover th,
.matrix tbody tr:hover td {
  background: color-mix(in srgb, var(--paper-2) 60%, var(--paper));
}

.matrix tbody tr:hover td.subject {
  background: var(--accent-wash);
}

.measures-more {
  display: block;
  width: fit-content;
  margin-top: 12px;
  color: var(--accent);
  text-decoration: none;
  border-bottom: 1px solid currentColor;
}

.measure-note {
  position: relative;
  top: -0.32em;
  display: inline-block;
  margin-left: -0.06em;
  font-size: inherit;
  line-height: 1;
}

.measure-note-trigger {
  display: inline-block;
  font-size: 11px;
}

.measure-note-popover {
  position: absolute;
  top: calc(100% + 10px);
  right: -8px;
  bottom: auto;
  transform: translateY(4px);
}

.measure-note:hover .measure-note-popover,
.measure-note:focus-within .measure-note-popover {
  opacity: 1;
  visibility: visible;
  transform: translateY(0);
}

@media (prefers-reduced-motion: reduce) {
  .metric-popover {
    transition: none;
  }
}

/* Inline code in prose. The default theme paints these with its brand colour,
   which the page now shares, but at a tint that does not shout, so they are
   restyled rather than left to
   clash. Code inside `.code` blocks keeps its own token colours. */
.cog :where(p, li, figcaption) code {
  font-family: var(--mono);
  font-size: 0.9em;
  color: var(--accent);
  background: var(--accent-wash);
  border-radius: 0;
  padding: 1px 5px;
}

/* ── Closing ────────────────────────────────────────────────────────
   Deliberately not another bordered panel. Every section above sits in a box
   or a table, so the page's last word is the one thing on it that does not:
   a hairline, the display face at hero scale, and the same two buttons the
   hero opened with. The measure is held narrow so the paragraph reads as a
   closing remark rather than as another column of body copy. */
.closing {
  display: grid;
  grid-template-columns: minmax(0, 1.4fr) minmax(0, 1fr);
  align-items: start;
  gap: 40px;
  margin-top: 88px;
  padding-top: 40px;
  border-top: 1px solid var(--rule);
}

.closing h2 {
  font-size: 40px;
  line-height: 1.05;
  margin: 0 0 12px;
}

.closing-text p {
  margin: 0 0 26px;
  max-width: 54ch;
  color: var(--ink-2);
  font-size: 13.5px;
}

/* The hero's `.actions` carries a bottom margin that separates it from the
   fact row underneath. There is no fact row here. */
.closing .actions {
  margin-bottom: 0;
}

/* The long tail, in the column the remark leaves empty. These are not ranked
   against each other, so they get no ordering, no captions, and no button
   chrome — hairlines alone are enough to read them as a list. */
.closing-more {
  list-style: none;
  margin: 0;
  padding: 0;
  align-self: start;
}

/* The rules go between the rows and nowhere else. Closing the list off at
   its top and bottom drew a box edge that sat a few pixels under the
   section's own rule and read as a second, shorter separator. */
.closing-more li + li a {
  border-top: 1px solid var(--rule);
}

.closing-more a {
  display: block;
  padding: 9px 0;
  color: var(--ink-2);
  font-size: 12.5px;
  text-decoration: none;
  transition: color 0.16s ease;
}

.closing-more a:hover {
  color: var(--accent);
}

/* ── The notifier's output ──────────────────────────────────────────
   Pinned to the viewport, not to the panel, because the section's claim is
   that this work leaves the graph — a notification drawn inside the diagram
   would be one more box in it. The stack never takes pointer events, so an
   effect landing mid-click cannot steal the next one. */
.toast-stack {
  position: fixed;
  right: 24px;
  bottom: 24px;
  z-index: 90;
  display: grid;
  gap: 10px;
  width: min(330px, calc(100vw - 48px));
  pointer-events: none;
}

.toast {
  display: grid;
  grid-template-columns: 28px minmax(0, 1fr);
  gap: 13px;
  padding: 14px 16px;
  border: 1px solid var(--rule-2);
  border-left: 3px solid var(--live);
  background: var(--paper);
  box-shadow: 0 14px 34px -14px rgba(13, 13, 18, 0.42);
}

/* On the dark ground `--paper` is the ground, so a toast painted with it has
   nothing but its border to sit on. The panel tone lifts it instead. */
.cog.dark .toast {
  background: var(--paper-2);
  box-shadow: 0 14px 34px -10px rgba(0, 0, 0, 0.8);
}

.toast-icon {
  display: grid;
  place-items: center;
  width: 28px;
  height: 28px;
  border: 1px solid var(--rule-2);
  color: var(--live);
}

.toast-icon svg {
  width: 16px;
  height: 16px;
  stroke-linecap: round;
  stroke-linejoin: round;
}

.toast-body p {
  margin: 0;
}

.toast-meta {
  display: flex;
  align-items: baseline;
  justify-content: space-between;
  gap: 12px;
  color: var(--ink-3);
  font-size: 9.5px;
  letter-spacing: 0.15em;
  text-transform: uppercase;
}

.toast-body .toast-title {
  margin-top: 5px;
  color: var(--ink);
  font-size: 13px;
}

.toast-body .toast-detail {
  margin-top: 3px;
  color: var(--ink-2);
  font-size: 11.5px;
  line-height: 1.5;
}

/* The toast arrives from below the fold and leaves sideways, so a stack that
   is both gaining and losing entries never reads as one item flickering. */
.toast-enter-active,
.toast-leave-active,
.toast-move {
  transition:
    opacity 0.28s ease,
    transform 0.28s ease;
}

.toast-enter-from {
  opacity: 0;
  transform: translateY(14px);
}

.toast-leave-to {
  opacity: 0;
  transform: translateX(18px);
}

/* Toasts expire in the order they arrived, so the one leaving is always the
   top of the stack; taking it out of flow there lets the rest slide up under
   it instead of snapping once it is gone. */
.toast-leave-active {
  position: absolute;
  top: 0;
  left: 0;
  right: 0;
}

@media (prefers-reduced-motion: reduce) {
  .toast-enter-active,
  .toast-leave-active,
  .toast-move {
    transition: none;
  }
}

/* ── Narrow ─────────────────────────────────────────────────────── */
@media (max-width: 880px) {
  .hero,
  .split,
  .closing {
    grid-template-columns: minmax(0, 1fr);
    gap: 32px;
  }
  .hero {
    padding-top: 64px;
  }
  .panel {
    padding: 22px;
  }
  .mechanism-stage {
    grid-template-columns: minmax(0, 1fr);
    grid-template-areas:
      "source"
      "lanes"
      "controls"
      "log";
    grid-template-rows: auto;
    gap: 22px;
  }
  .mechanism-controls,
  .mechanism-history {
    margin-top: 0;
  }
  .measures-text {
    max-width: 62ch;
  }
  /* One column, and the facts and links follow what they annotate rather than
     sitting beside it. Stacked, the four facts would cost four rows of a page
     that is already scrolling, so they pair up instead. */
  .install-pane {
    grid-template-columns: minmax(0, 1fr);
    gap: 26px;
  }

  .install-facts {
    display: grid;
    grid-template-columns: repeat(2, minmax(0, 1fr));
    column-gap: 28px;
  }
}

@media (max-width: 600px) {
  .mechanism-log li {
    grid-template-columns: minmax(0, 1fr);
    gap: 4px;
  }

  /* The switch stops being a right-hand control and becomes a full-width one
     under the heading. The UI-framework word is the first thing to go: at this
     width it would wrap one option to two lines and leave the two halves of a
     single control at different heights. */
  .platform-switch {
    width: 100%;
  }

  .platform-switch button {
    flex: 1;
    justify-content: center;
    gap: 8px;
  }

  .switch-sub {
    display: none;
  }

  /* Two columns of facts fit 820px, not 390: the values start wrapping and
     cost back the rows the pairing saved. */
  .install-facts {
    grid-template-columns: minmax(0, 1fr);
  }
}
</style>
