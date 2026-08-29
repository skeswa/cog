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
          <a class="btn btn-primary" :href="withBase('/documentation/cog/gettingstarted')">
            Get started
          </a>
          <a class="btn" :href="withBase('/swift/')">Learn more</a>
        </div>
        <dl class="facts">
          <div>
            <dt>Swift</dt>
            <dd>
              <a class="release-link" href="https://github.com/skeswa/cog/releases/latest">
                0.5.0
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

    <!-- ── Graph demo ───────────────────────────────────────────────── -->
    <section ref="root" class="panel" aria-labelledby="graph-title">
      <div class="panel-head">
        <h2 id="graph-title">What updates when state changes</h2>
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

    <!-- ── Measurements ─────────────────────────────────────────────── -->
    <section class="panel measures" aria-labelledby="measures-title">
      <div class="panel-head">
        <h2 id="measures-title">Minimal overhead</h2>
        <p>These results come from benchmark thresholds checked in CI.</p>
      </div>
      <div class="grid">
        <figure>
          <div class="figure-num">0</div>
          <figcaption>
            <b>allocations in a steady turn</b>
            All 1,751 samples report zero at every percentile. The previous result was 7, and CI now
            requires zero.
          </figcaption>
        </figure>
        <figure>
          <div class="figure-num">0</div>
          <figcaption>
            <b>allocations settling 100 nodes</b>
            Settling one source through 100 derived values previously allocated 107 objects. It now
            allocates none.
          </figcaption>
        </figure>
        <figure>
          <div class="figure-num">12</div>
          <figcaption>
            <b>observation boundaries of 1,000</b>
            The graph contained 1,000 states, 12 of which were read. The run created 12 observation
            boundaries at p0 and p100.
          </figcaption>
        </figure>
        <figure>
          <div class="figure-num">1.64<span class="unit">µs</span></div>
          <figcaption>
            <b>steady turn latency</b>
            This benchmark previously measured 2.20 µs. Its cost stays flat from 1 pinned key
            through 1,000.
          </figcaption>
        </figure>
      </div>
      <p class="footnote">
        Measurements use release builds on a 12-core Apple M4 Pro with 24 GB of memory, running
        macOS 26.4.1, Xcode 26.4 (17E192), and Swift 6.3, with allocation counts provided by a
        malloc interposer. The
        <a :href="withBase('/swift/impl/benchmarks')">benchmark record</a>
        includes the environment details and full tables.
      </p>
    </section>

    <!-- ── Principles ───────────────────────────────────────────────── -->
    <section class="principles" aria-labelledby="principles-title">
      <h2 id="principles-title">Core rules</h2>
      <ol>
        <li>
          <span class="rule-n">01</span>
          <div>
            <b>Keep it simple.</b>
            State should be easy to declare, read, and change. The API keeps runtime details out of
            app code.
          </div>
        </li>
        <li>
          <span class="rule-n">02</span>
          <div>
            <b>Make every read correct.</b>
            Before a read returns, Cog settles the dependencies it needs against the latest
            committed state. This prevents torn updates and stale derived values.
          </div>
        </li>
        <li>
          <span class="rule-n">03</span>
          <div>
            <b>Measure the overhead.</b>
            Benchmarks track recomputation, memory allocation, and view updates. They also compare
            Cog with other implementations.
          </div>
        </li>
        <li>
          <span class="rule-n">04</span>
          <div>
            <b>Keep one source of truth.</b>
            A running app has one authoritative graph. Each mutable fact has one writable source in
            that graph.
          </div>
        </li>
      </ol>
    </section>

    <!-- ── Platforms ────────────────────────────────────────────────── -->
    <section class="platforms" aria-labelledby="platforms-title">
      <h2 id="platforms-title">Swift and Kotlin</h2>
      <div class="cards">
        <a class="card" :href="withBase('/swift/')">
          <span class="card-tag shipping">Released · 0.5.0</span>
          <h3>Swift for SwiftUI</h3>
          <p>
            The Swift library uses <code>@Observable</code> at the UI boundary and keeps one
            MainActor-confined graph for the app. It supports mechanisms, declared lifetimes, async
            state and streams, value exports, and SwiftPM lint plugins.
          </p>
          <span class="card-go">Read the Swift docs →</span>
        </a>
        <a class="card" :href="withBase('/kotlin/')">
          <span class="card-tag planned">Designed</span>
          <h3>Kotlin for Compose</h3>
          <p>
            The Kotlin design uses Compose snapshot state at the UI boundary and keeps state in one
            process-wide store. It defines turn, lifetime, and async behavior. The library is not
            implemented yet.
          </p>
          <span class="card-go">Read the Kotlin design →</span>
        </a>
      </div>
    </section>

    <!-- ── Install ──────────────────────────────────────────────────── -->
    <section class="install" aria-labelledby="install-title">
      <h2 id="install-title">Install Cog</h2>
      <pre class="code install-code"><code>.package(
  url: <span class="s">"https://github.com/skeswa/cog.git"</span>,
  .upToNextMinor(from: <span class="s">"0.5.0"</span>)
)</code></pre>
      <p>
        Cog is still in 0.x, so a minor release may include source-breaking changes; the changelog
        records them. The package requires iOS 17 or macOS 14.
      </p>
    </section>
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

  --display: "Instrument Serif", ui-serif, Georgia, serif;
  --mono: "JetBrains Mono", ui-monospace, "SF Mono", Menlo, monospace;

  color: var(--ink);
  font-family: var(--mono);
  font-size: 15px;
  line-height: 1.65;
  max-width: 1180px;
  margin: 0 auto;
  padding: 0 24px 120px;
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
  border-bottom: 1px solid var(--rule);
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

/* ── Panels ─────────────────────────────────────────────────────── */
.panel {
  margin-top: 88px;
  border: 1px solid var(--rule);
  background: color-mix(in srgb, var(--paper-2) 70%, transparent);
  padding: 34px;
}

.panel-head h2,
.split-text h2,
.principles h2,
.platforms h2,
.install h2 {
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

/* ── Measurements ───────────────────────────────────────────────── */
.measures {
  margin-top: 88px;
}

.measures .grid {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
  gap: 1px;
  background: var(--rule);
  border: 1px solid var(--rule);
}

.measures figure {
  margin: 0;
  padding: 26px 22px;
  background: var(--paper);
}

.figure-num {
  font-family: var(--display);
  font-size: 62px;
  line-height: 1;
  color: var(--accent);
  margin-bottom: 12px;
}

.figure-num .unit {
  font-size: 24px;
  color: var(--ink-2);
  margin-left: 3px;
}

.measures figcaption {
  font-size: 12.5px;
  color: var(--ink-2);
  line-height: 1.6;
}

.measures figcaption b {
  display: block;
  color: var(--ink);
  font-weight: 500;
  margin-bottom: 6px;
}

.footnote {
  margin: 20px 0 0;
  font-size: 11.5px;
  color: var(--ink-3);
}

.footnote a {
  color: var(--ink-2);
}

/* ── Principles ─────────────────────────────────────────────────── */
.principles {
  margin-top: 88px;
}

.principles ol {
  list-style: none;
  margin: 24px 0 0;
  padding: 0;
  border-top: 1px solid var(--rule);
}

.principles li {
  display: grid;
  grid-template-columns: 64px minmax(0, 1fr);
  gap: 0 20px;
  padding: 22px 0;
  border-bottom: 1px solid var(--rule);
  font-size: 13.5px;
  color: var(--ink-2);
}

.rule-n {
  font-family: var(--display);
  font-size: 26px;
  color: var(--accent);
  line-height: 1;
}

.principles b {
  display: block;
  color: var(--ink);
  font-weight: 500;
  margin-bottom: 3px;
}

/* ── Platforms ──────────────────────────────────────────────────── */
.platforms {
  margin-top: 88px;
}

.cards {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(280px, 1fr));
  gap: 20px;
  margin-top: 24px;
}

.card {
  display: block;
  padding: 28px;
  border: 1px solid var(--rule);
  text-decoration: none;
  color: inherit;
  background: color-mix(in srgb, var(--paper-2) 70%, transparent);
  transition:
    border-color 0.18s ease,
    transform 0.18s ease;
}

.card:hover {
  border-color: var(--accent);
  transform: translateY(-2px);
}

.card-tag {
  font-size: 10.5px;
  letter-spacing: 0.14em;
  text-transform: uppercase;
  padding: 3px 9px;
  border: 1px solid currentColor;
}

.card-tag.shipping {
  color: var(--live);
}
.card-tag.planned {
  color: var(--ink-3);
}

.card h3 {
  font-family: var(--display);
  font-size: 27px;
  margin: 16px 0 10px;
}

.card p {
  font-size: 13px;
  color: var(--ink-2);
  margin: 0 0 16px;
}

.card-go {
  font-size: 12px;
  color: var(--accent);
}

/* ── Install ────────────────────────────────────────────────────── */
.install {
  margin-top: 88px;
  border-top: 1px solid var(--rule);
  padding-top: 44px;
}

.install-code {
  margin: 20px 0 14px;
  max-width: 620px;
}

.install > p {
  font-size: 12.5px;
  color: var(--ink-2);
  max-width: 62ch;
  margin: 0;
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

/* ── Narrow ─────────────────────────────────────────────────────── */
@media (max-width: 880px) {
  .hero,
  .split {
    grid-template-columns: minmax(0, 1fr);
    gap: 32px;
  }
  .hero {
    padding-top: 64px;
  }
  .panel {
    padding: 22px;
  }
}
</style>
