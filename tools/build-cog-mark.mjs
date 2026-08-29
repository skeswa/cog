#!/usr/bin/env node
// Builds the Cog mark — two meshing gears — into every form the project shows
// it in, from one description of the geometry.
//
// There are two consumers and they cannot share a file. The documentation site
// needs a Vue component, because only an inline SVG can take its colours from
// the theme's custom properties and follow the light and dark palettes. The
// repository README is rendered by GitHub, which strips inline `<svg>` out of
// Markdown entirely and allows only `<img>` — so that consumer needs standalone
// SVG files instead, one per palette, each carrying its own baked colours and
// the wordmark as outlines rather than as text.
//
// The outlines are not an optimisation. GitHub serves README images through
// its camo proxy under `default-src 'none'; img-src data:; style-src
// 'unsafe-inline'`. That policy allows the inline stylesheet, which is what
// keeps the gears turning, but it has no `font-src`, so the directive falls
// back to `'none'` and every font is refused — including one embedded in the
// file as a data URI. A lockup that set its wordmark as text would render in
// whatever serif the reader happened to have. Drawn as outlines it needs no
// font at all, and the file is a twentieth of the size it would otherwise be.
//
// Writing those by hand would mean maintaining the same involute tooth
// geometry in three places, so this script emits all three. Run it after
// changing anything about the mark:
//
//     mise run docs:mark
//
// What it does not own is the palette. Those values live in `theme.css`, where
// the site needs them anyway, and are read back out here so the README can
// never drift from the navigation bar.

import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const THEME_CSS = join(ROOT, "docs/.vitepress/theme/theme.css");
const COMPONENT = join(ROOT, "docs/.vitepress/theme/CogMark.vue");
const LOCKUP = (name) => join(ROOT, `docs/public/cog-lockup-${name}.svg`);

const round = (x) => Math.round(x * 1000) / 1000;

// ── The gears ─────────────────────────────────────────────────────────────
//
// A pair of gears turns at a constant ratio without its teeth fouling only
// because the involute is the profile whose contact point travels a straight
// line as the wheels rotate. The mark turns forever, so its teeth are cut the
// way real ones are rather than drawn as a sawtooth, which would jam somewhere
// in the cycle. `verifyMesh` below measures that this actually holds.

const TAU = Math.PI * 2;
const involute = (a) => Math.tan(a) - a;

/**
 * One gear's dimensions and the half-profile of a single tooth flank.
 *
 * `add` and `ded` are the addendum and dedendum in modules — how far a tooth
 * stands above the pitch circle and how far the gap is cut below it. `w` and
 * `t` fall out of the pressure angle rather than being chosen. `backlash`
 * thins every tooth by the same arc length on both flanks, which is the only
 * dial that opens clearance without changing how the gear reads.
 */
function gear({ n, m, alpha = 14.5, add = 0.6, ded = 0.8, backlash = 0.16, steps = 7 }) {
  const a = (alpha * Math.PI) / 180;
  const rP = (m * n) / 2;
  const rB = rP * Math.cos(a);
  const rA = rP + add * m;
  const rF = rP - ded * m;
  const halfP = ((Math.PI * m) / 2 - backlash * m) / (2 * rP);
  const invP = involute(a);
  const half = (r) => (r <= rB ? halfP + invP : halfP + invP - involute(Math.acos(rB / r)));
  const rStart = Math.max(rB, rF);

  const flank = [];
  for (let i = 0; i <= steps; i++) {
    const r = rStart + ((rA - rStart) * i) / steps;
    flank.push([r, half(r)]);
  }
  return { n, m, rP, rA, rF, rStart, flank, halfRoot: half(rStart) };
}

/** The closed outline of one gear, with real arcs across the tips and roots. */
function outlinePath(g, cx, cy, phase) {
  const step = TAU / g.n;
  const P = (r, t) => `${round(cx + r * Math.cos(t))} ${round(cy + r * Math.sin(t))}`;
  let d = "";
  for (let i = 0; i < g.n; i++) {
    const th = phase + i * step;
    const tip = g.flank[g.flank.length - 1][1];
    for (const [r, h] of g.flank) d += (d === "" ? "M" : "L") + P(r, th - h);
    d += `A${round(g.rA)} ${round(g.rA)} 0 0 1 ${P(g.rA, th + tip)}`;
    for (let j = g.flank.length - 2; j >= 0; j--) d += "L" + P(g.flank[j][0], th + g.flank[j][1]);
    if (g.rF < g.rStart) d += "L" + P(g.rF, th + g.halfRoot);
    d += `A${round(g.rF)} ${round(g.rF)} 0 0 1 ${P(g.rF, th + step - g.halfRoot)}`;
    if (g.rF < g.rStart) d += "L" + P(g.rStart, th + step - g.halfRoot);
  }
  return d + "Z";
}

/** A full circle as its own subpath, which `fill-rule="evenodd"` turns into a hole. */
const ringPath = (cx, cy, r) =>
  `M${round(cx + r)} ${round(cy)}A${round(r)} ${round(r)} 0 1 0 ${round(cx - r)} ${round(cy)}` +
  `A${round(r)} ${round(r)} 0 1 0 ${round(cx + r)} ${round(cy)}Z`;

/** The outline sampled densely, for the clearance measurement only. */
function outlinePoints(g, phase, perArc = 10) {
  const pts = [];
  const step = TAU / g.n;
  const P = (r, t) => [r * Math.cos(t), r * Math.sin(t)];
  for (let i = 0; i < g.n; i++) {
    const th = phase + i * step;
    const tip = g.flank[g.flank.length - 1][1];
    for (const [r, h] of g.flank) pts.push(P(r, th - h));
    for (let k = 1; k < perArc; k++) pts.push(P(g.rA, th - tip + (2 * tip * k) / perArc));
    for (let j = g.flank.length - 1; j >= 0; j--) pts.push(P(g.flank[j][0], th + g.flank[j][1]));
    const from = th + g.halfRoot;
    const to = th + step - g.halfRoot;
    for (let k = 0; k <= perArc; k++) pts.push(P(g.rF, from + ((to - from) * k) / perArc));
  }
  return pts;
}

// ── The pair ──────────────────────────────────────────────────────────────

const MODULE = 1.292;
const PROFILE = { alpha: 14.5, add: 0.6, ded: 0.8, backlash: 0.16 };
const TEETH_LARGE = 12;
const TEETH_SMALL = 8;
/** Where the small gear sits, as a bearing from the large gear's axle. */
const BEARING = (-50 * Math.PI) / 180;

// The hub, in fractions of the root radius: a dished ring, a raised boss, and
// the bore. Every layer is punched at `BORE` so the hole goes right through.
const BORE = 0.24;
const BOSS = 0.46;
const RECESS = 0.7;

// The top face is the same gear cut a shade smaller all round — shorter teeth,
// deeper roots, thinner flanks — which is what an inward offset of the outline
// amounts to. Laid over the full-size outline it leaves a chamfer of even
// width, and because both copies turn together the bevel stays welded to its
// teeth instead of sweeping around them.
const INSET = 0.2;
const inset = (p) => ({
  ...p,
  add: p.add - INSET,
  ded: p.ded + INSET,
  backlash: p.backlash + 0.22,
});

const large = gear({ n: TEETH_LARGE, m: MODULE, ...PROFILE });
const small = gear({ n: TEETH_SMALL, m: MODULE, ...PROFILE });
const largeFace = gear({ n: TEETH_LARGE, m: MODULE, ...inset(PROFILE) });
const smallFace = gear({ n: TEETH_SMALL, m: MODULE, ...inset(PROFILE) });

const centres = large.rP + small.rP;
const smallAt = [round(centres * Math.cos(BEARING)), round(centres * Math.sin(BEARING))];

// A gap of the large gear points at the small gear and a tooth of the small
// gear points back, which is the pair's meshing phase.
const PHASE_LARGE = BEARING - Math.PI / TEETH_LARGE;
const PHASE_SMALL = BEARING + Math.PI;

const GEARS = [
  { key: "large", id: "a", g: large, face: largeFace, cx: 0, cy: 0, phase: PHASE_LARGE },
  {
    key: "small",
    id: "b",
    g: small,
    face: smallFace,
    cx: smallAt[0],
    cy: smallAt[1],
    phase: PHASE_SMALL,
  },
];

const markBox = (() => {
  const xs = GEARS.flatMap(({ g, cx }) => [cx - g.rA, cx + g.rA]);
  const ys = GEARS.flatMap(({ g, cy }) => [cy - g.rA, cy + g.rA]);
  const pad = 0.4;
  return {
    x: round(Math.min(...xs) - pad),
    y: round(Math.min(...ys) - pad),
    width: round(Math.max(...xs) - Math.min(...xs) + 2 * pad),
    height: round(Math.max(...ys) - Math.min(...ys) + 2 * pad),
  };
})();

/**
 * The narrowest gap between the two outlines over a full meshing cycle.
 *
 * Involute teeth are supposed to clear at every angle, but "supposed to" is not
 * a measurement, and the tooth proportions above are chosen for how the mark
 * reads rather than for any standard. So the cycle is swept and the closest
 * approach reported. If this ever comes back at or below zero the gears
 * intersect somewhere in the turn, and the mark is broken in a way that only
 * shows for a fraction of a second every half-minute.
 */
function verifyMesh(phases = 72) {
  const pitchPoint = [large.rP * Math.cos(BEARING), large.rP * Math.sin(BEARING)];
  const near = (p) =>
    (p[0] - pitchPoint[0]) ** 2 + (p[1] - pitchPoint[1]) ** 2 < (3.2 * MODULE) ** 2;
  const toSegment = (p, a, b) => {
    const vx = b[0] - a[0];
    const vy = b[1] - a[1];
    const len = vx * vx + vy * vy;
    const t =
      len === 0 ? 0 : Math.max(0, Math.min(1, ((p[0] - a[0]) * vx + (p[1] - a[1]) * vy) / len));
    return Math.hypot(p[0] - (a[0] + t * vx), p[1] - (a[1] + t * vy));
  };

  let worst = Infinity;
  for (let k = 0; k < phases; k++) {
    const turn = ((TAU / TEETH_LARGE) * k) / phases;
    const a = outlinePoints(large, PHASE_LARGE + turn);
    const b = outlinePoints(small, PHASE_SMALL - turn * (TEETH_LARGE / TEETH_SMALL)).map((p) => [
      p[0] + smallAt[0],
      p[1] + smallAt[1],
    ]);
    for (const p of a.filter(near))
      for (let i = 0; i < b.length; i++)
        worst = Math.min(worst, toSegment(p, b[i], b[(i + 1) % b.length]));
    for (const p of b.filter(near))
      for (let i = 0; i < a.length; i++)
        worst = Math.min(worst, toSegment(p, a[i], a[(i + 1) % a.length]));
  }
  return worst;
}

// ── Shared markup ─────────────────────────────────────────────────────────
//
// Each gear is drawn as three layers, separated by one question: does the piece
// turn, and does its lighting turn with it? See the component's own comment,
// which this script writes, for what each layer is doing.

const plate = (g, cx, cy, phase) =>
  outlinePath(g, cx, cy, phase) + ringPath(cx, cy, round(g.rF * BORE));
const annulus = (cx, cy, outer, inner) =>
  ringPath(cx, cy, round(outer)) + ringPath(cx, cy, round(inner));

const DEFS = `    <defs>
      <!-- The plate. Centred on the axle, so rotation cannot disturb it. The
           small gear is cut one step lighter so the pair still reads as two
           bodies where the teeth mesh a fifth of a pixel apart. -->
      <radialGradient id="cog-plate-a" cx="50%" cy="50%" r="50%">
        <stop class="cog-mark__stop-1" offset="0%" />
        <stop class="cog-mark__stop-2" offset="40%" />
        <stop class="cog-mark__stop-2" offset="100%" />
      </radialGradient>
      <radialGradient id="cog-plate-b" cx="50%" cy="50%" r="50%">
        <stop class="cog-mark__stop-0" offset="0%" />
        <stop class="cog-mark__stop-1" offset="40%" />
        <stop class="cog-mark__stop-1" offset="100%" />
      </radialGradient>

      <!-- The relief, in white and black alone so one set of gradients serves
           either gear's tone and both palettes. Light from the upper left. -->
      <linearGradient id="cog-sheen" x1="14%" y1="0%" x2="76%" y2="100%">
        <stop offset="0%" stop-color="#fff" stop-opacity="0.5" />
        <stop offset="42%" stop-color="#fff" stop-opacity="0.06" />
        <stop offset="62%" stop-color="#000" stop-opacity="0.04" />
        <stop offset="100%" stop-color="#000" stop-opacity="0.26" />
      </linearGradient>
      <linearGradient id="cog-recess" x1="20%" y1="0%" x2="80%" y2="100%">
        <stop offset="0%" stop-color="#000" stop-opacity="0.42" />
        <stop offset="100%" stop-color="#fff" stop-opacity="0.28" />
      </linearGradient>
      <linearGradient id="cog-boss" x1="20%" y1="0%" x2="80%" y2="100%">
        <stop offset="0%" stop-color="#fff" stop-opacity="0.38" />
        <stop offset="100%" stop-color="#000" stop-opacity="0.26" />
      </linearGradient>

${GEARS.map(
  ({ key, id, g, cx, cy, phase }) => `      <mask id="cog-body-${id}">
        <g class="cog-mark__gear cog-mark__gear--${key}">
          <circle cx="${cx}" cy="${cy}" r="${round(g.rA)}" fill="none" />
          <path fill="#fff" d="${plate(g, cx, cy, phase)}" />
        </g>
      </mask>`,
).join("\n")}
    </defs>`;

const BODY = GEARS.map(
  ({ key, id, g, face, cx, cy, phase }) => `    <g class="cog-mark__gear cog-mark__gear--${key}">
      <circle cx="${cx}" cy="${cy}" r="${round(g.rA)}" fill="none" />
      <path class="cog-mark__chamfer" d="${plate(g, cx, cy, phase)}" />
      <path class="cog-mark__face" fill="url(#cog-plate-${id})" d="${outlinePath(face, cx, cy, phase) + ringPath(cx, cy, round(g.rF * BORE))}" />
    </g>
    <rect
      class="cog-mark__sheen"
      mask="url(#cog-body-${id})"
      fill="url(#cog-sheen)"
      x="${round(cx - g.rA)}"
      y="${round(cy - g.rA)}"
      width="${round(2 * g.rA)}"
      height="${round(2 * g.rA)}"
    />
    <g class="cog-mark__hub">
      <path class="cog-mark__recess" fill="url(#cog-recess)" d="${annulus(cx, cy, g.rF * RECESS, g.rF * BOSS)}" />
      <path class="cog-mark__boss" fill="url(#cog-boss)" d="${annulus(cx, cy, g.rF * BOSS, g.rF * BORE)}" />
      <circle class="cog-mark__bore" cx="${cx}" cy="${cy}" r="${round(g.rF * BORE)}" />
    </g>`,
).join("\n");

// ── The site component ────────────────────────────────────────────────────

const COMPONENT_DOC = `<script setup lang="ts">
/**
 * The Cog mark: two meshing gears that turn to the left of the "Cog" wordmark
 * in the navigation bar.
 *
 * Generated by \`tools/build-cog-mark.mjs\` — edit that, then run
 * \`mise run docs:mark\`. The same script emits the standalone lockups in
 * \`docs/public/\` that the repository README shows, so the mark cannot differ
 * between the site and GitHub.
 *
 * The outlines are generated geometry rather than drawn art, and the tooth
 * flanks are true involutes of a circle. That is not decoration. A pair of
 * gears can turn continuously at a constant ratio without their teeth fouling
 * only because the involute is the profile whose contact point travels a
 * straight line as the wheels rotate; a hand-drawn sawtooth jams somewhere in
 * the cycle. Since this mark turns forever, its teeth have to be shaped like
 * the real thing.
 *
 * Both gears are cut with the same module — the same tooth pitch measured
 * along the pitch circle — at a 14.5 degree pressure angle, the shallow end of
 * the standard range, which gives the flat-flanked, short-toothed profile that
 * reads as a gear at a glance. Twelve teeth against eight puts the wheels at a
 * 3:2 ratio and their centres exactly one pitch radius apart in each
 * direction. The phases are set so a gap of the large gear points at the small
 * gear while a tooth of the small gear points back. The clearance is measured
 * rather than assumed: the build sweeps a full meshing cycle and fails if the
 * outlines ever touch. They come no closer than MESH units, about a fifth of a
 * pixel at the size the navigation bar draws them.
 *
 * Each gear is drawn as three layers, and what separates them is a single
 * question: does this piece turn, and does its lighting turn with it?
 *
 * The metal turns. The full outline is filled with the darkest step, and a
 * copy of it cut a shade smaller all round is laid on top in the body tone,
 * which leaves a chamfer of even width around every tooth — the bevel a
 * machined edge catches. Both copies turn together, so that bevel stays welded
 * to the teeth it belongs to. The body tone is a radial gradient centred on
 * the axle, the one kind of colour shading that is invariant under rotation.
 *
 * The light does not turn. It is one directional wash — white where the light
 * falls, black on the far side — painted on a still rectangle and cut to shape
 * by a mask holding a second copy of the silhouette that turns in step with
 * the first. The mask moves and the gradient stays put, so the teeth pass
 * through a fixed light instead of each carrying its own highlight around with
 * it, which is the tell that gives away a spinning texture rather than a
 * turning object.
 *
 * The hub relief does not turn either, and here that costs nothing: a dished
 * ring, a raised boss, and a dark rim inside the bore are all concentric
 * circles, and a circle looks the same rotated. Their shading is white and
 * black at low alpha rather than colour, so one set of gradients serves either
 * gear's tone and both palettes.
 *
 * Each outline is a closed subpath followed by a second for the bore, and
 * \`fill-rule="evenodd"\` makes that second subpath a hole rather than a disc.
 * Every layer is punched at the same radius, so the bore is a real hole: the
 * mark carries no background colour of its own and stays correct on the light
 * ground, the dark ground, and the landing page's tinted panels alike.
 *
 * The gradient and mask ids are document-global, so this component may be
 * rendered only once per page — and is: \`Layout.vue\` slots it into the
 * navigation title and nowhere else. A second copy would resolve those
 * references to the first copy's definitions and mask itself with the first
 * copy's silhouette, frozen at whatever angle that one had reached.
 *
 * Each turning group carries an unpainted circle at its tip radius, which is
 * what keeps the rotation on the axle. A gear has to turn about its own
 * centre, and the only transform origin that survives being nested inside a
 * \`viewBox\` whose corner is not the coordinate origin is
 * \`transform-box: fill-box\` with \`transform-origin: center\` — and that
 * centres on the group's bounding box, not on the axle. The two coincide here
 * only because both tooth counts are even, which makes each outline centrally
 * symmetric; an odd count would put the bounding box off centre and leave the
 * gear visibly wobbling as it turned. The circle is concentric with the axle
 * and exactly as wide as the widest tooth, so it pins the bounding box to the
 * axle for any tooth count without painting anything.
 *
 * \`aria-hidden\` is deliberate: the accessible name of the link is already the
 * "Cog" text node that follows the mark inside the same anchor, and announcing
 * the drawing again would only repeat it.
 */
</script>

<template>
  <svg
    class="cog-mark"
    viewBox="${markBox.x} ${markBox.y} ${markBox.width} ${markBox.height}"
    fill-rule="evenodd"
    aria-hidden="true"
  >
${DEFS}

${BODY}
  </svg>
</template>
`;

// ── The standalone lockups ────────────────────────────────────────────────
//
// Metrics for "Cog" in Instrument Serif, measured off the loaded face at a
// font size of 100 and scaled from there. The site sets the wordmark in 23px
// beside a 30px mark, which fixes the type size relative to the geometry; the
// mark is lifted so the large gear's axle lands on the middle of the ink,
// between the cap of the C and the descender of the g, and the same
// relationship is rebuilt here.
const WORDMARK = {
  /**
   * "Cog" in Instrument Serif 400, traced at an em size of 1000 with its
   * origin on the baseline at the start of the first glyph.
   *
   * Traced once rather than at build time, because the only parser to hand
   * cannot read the WOFF2 the site loads and trips over this font's GSUB
   * table when shaping, so the glyphs were composed one at a time from
   * `@fontsource/instrument-serif`'s WOFF. Three glyphs of a pinned font do
   * not move. If the wordmark or the typeface ever does change, retrace it:
   * walk the string with `charToGlyph`, place each `getPath` at the running
   * pen position, and advance by `advanceWidth` plus `getKerningValue`.
   *
   * The metrics below were cross-checked against the same face as the
   * browser lays it out — canvas `measureText` reports the identical advance
   * of 1290 and identical ink bounds — so this draws what the site draws.
   */
  d: "M286 9Q212 9 156.50-37Q101-83 70.50-166.50Q40-250 40-364Q40-474 73.50-556.50Q107-639 163.50-684.50Q220-730 289-730Q330-730 361-722.50Q392-715 416-703Q428-696 428-682L431-530Q431-513 419-513Q408-513 405-526L395-563Q374-641 346.50-671Q319-701 281-701Q211-701 164.50-614.50Q118-528 118-364Q118-252 141.50-175Q165-98 202.50-59Q240-20 282-20Q327-20 354.50-48Q382-76 401-156L413-205Q416-220 429-218Q440-216 440-201L436-39Q436-25 423-18Q399-6 366.50 1.50Q334 9 286 9M683 9Q632 9 591.50-25.50Q551-60 527-120Q503-180 503-254Q503-328 527-387Q551-446 592-481Q633-516 683-516Q734-516 774.50-481Q815-446 839-387Q863-328 863-254Q863-180 839.50-120Q816-60 775-25.50Q734 9 683 9M683-16Q787-16 787-254Q787-491 683-491Q579-491 579-254Q579-16 683-16M1066 215Q990 215 946 184.50Q902 154 902 111Q902 93 907 78.50Q912 64 928.50 45Q945 26 979-4Q991-15 991-24.50Q991-34 979-39Q943-54 936-77.50Q929-101 953-121L1025-183Q1037-193 1024-200Q983-220 959-262Q935-304 935-352Q935-398 955-435Q975-472 1009-494Q1043-516 1085-516Q1109-516 1131-508Q1145-503 1148-517Q1157-555 1181.50-576.50Q1206-598 1230-598Q1253-598 1267.50-584.50Q1282-571 1282-551Q1282-534 1272-524Q1262-514 1247-514Q1234-514 1228-519Q1222-524 1217-529Q1212-534 1201-534Q1177-534 1171-508Q1168-498 1171.50-491Q1175-484 1182-477Q1206-454 1219.50-421Q1233-388 1233-348Q1233-300 1213.50-262Q1194-224 1160.50-202Q1127-180 1085-180Q1067-180 1054-172.50Q1041-165 1028-151L1011-132Q998-116 1003.50-101.50Q1009-87 1031-87L1117-87Q1189-87 1231-51.50Q1273-16 1273 46Q1273 95 1245 133Q1217 171 1170.50 193Q1124 215 1066 215M1084-205Q1120-205 1141-244Q1162-283 1162-350Q1162-415 1140.50-454.50Q1119-494 1084-494Q1049-494 1027.50-454.50Q1006-415 1006-350Q1006-283 1027-244Q1048-205 1084-205M1078 193Q1114 193 1144 177Q1174 161 1191.50 132.50Q1209 104 1209 68Q1209 23 1182.50-1.50Q1156-26 1108-26L1085-26Q1054-26 1038.50-20Q1023-14 1009 1Q978 34 970 54Q962 74 962 95Q962 139 992.50 166Q1023 193 1078 193",
  advance: 1290,
  ascent: 730,
  descent: 215,
  inkRight: 1282,
  em: 1000,
};

/**
 * The site sets the wordmark in 23px beside a 30px mark, which fixes the type
 * size against the geometry, and lifts the mark so the large gear's axle lands
 * on the middle of the ink — between the cap of the C and the descender of the
 * g. Both relationships are rebuilt here from the same numbers.
 */
const SITE = { fontPx: 23, markPx: 30, gapPx: 4 };

const unitPx = SITE.markPx / markBox.height;
const fontSize = SITE.fontPx / unitPx;
const scale = fontSize / WORDMARK.em;
const baseline = round(((WORDMARK.ascent - WORDMARK.descent) / 2) * scale);
const textX = round(markBox.x + markBox.width + SITE.gapPx / unitPx);
const textRight = textX + WORDMARK.inkRight * scale;
const inkTop = baseline - WORDMARK.ascent * scale;
const inkBottom = baseline + WORDMARK.descent * scale;

const PAD = 1;
const lockupBox = {
  x: round(markBox.x - PAD),
  y: round(Math.min(markBox.y, inkTop) - PAD),
  width: round(textRight - markBox.x + 2 * PAD),
  height: round(
    Math.max(markBox.y + markBox.height, inkBottom) - Math.min(markBox.y, inkTop) + 2 * PAD,
  ),
};
const SCALE = 3;

/**
 * Pull one palette out of `theme.css`, so the README cannot drift from the
 * site.
 *
 * The selector is matched at the start of a line and every one of its blocks
 * is considered, because `.cog-mark` carries more than one: the steps are
 * declared in a block of their own, separate from the one that sizes and
 * positions the mark in the navigation bar.
 */
function palette(css, selector) {
  const blocks = css.matchAll(new RegExp(`^${selector}\\s*\\{([^}]*)\\}`, "gm"));
  for (const [, body] of blocks) {
    const steps = {};
    for (const [, k, v] of body.matchAll(/--cog-mark-(\d):\s*([^;]+);/g)) steps[k] = v.trim();
    if (["0", "1", "2", "3"].every((k) => steps[k])) return steps;
  }
  throw new Error(`theme.css: no "${selector}" block declares --cog-mark-0 through -3`);
}

function lockup({ steps, ink }) {
  return `<svg
  xmlns="http://www.w3.org/2000/svg"
  viewBox="${lockupBox.x} ${lockupBox.y} ${lockupBox.width} ${lockupBox.height}"
  width="${round(lockupBox.width * SCALE)}"
  height="${round(lockupBox.height * SCALE)}"
  fill-rule="evenodd"
  role="img"
  aria-label="Cog"
>
  <title>Cog</title>
  <style>
    /* Baked rather than inherited: nothing outside this file reaches in. */
    .cog-mark__stop-0 { stop-color: ${steps[0]}; }
    .cog-mark__stop-1 { stop-color: ${steps[1]}; }
    .cog-mark__stop-2 { stop-color: ${steps[2]}; }
    .cog-mark__stop-3 { stop-color: ${steps[3]}; }
    .cog-mark__chamfer { fill: ${steps[3]}; }
    .cog-mark__gear--small .cog-mark__chamfer { fill: ${steps[2]}; }
    .cog-mark__bore {
      fill: none;
      stroke: ${steps[3]};
      stroke-width: 0.5;
      stroke-opacity: 0.55;
    }
    .cog-mark__word { fill: ${ink}; }

    /* Meshed teeth cannot slip, so the periods are the inverse of the tooth
       counts and the timing has to be linear. Both animations start on the
       same document timeline, so they hold the phase they were drawn in. */
    .cog-mark__gear { transform-box: fill-box; transform-origin: center; }
    .cog-mark__gear--large { animation: cog-mark-turn 36s linear infinite; }
    .cog-mark__gear--small { animation: cog-mark-turn-back 24s linear infinite; }
    @keyframes cog-mark-turn { to { transform: rotate(360deg); } }
    @keyframes cog-mark-turn-back { to { transform: rotate(-360deg); } }

    @media (prefers-reduced-motion: reduce) {
      .cog-mark__gear--large,
      .cog-mark__gear--small { animation: none; }
    }
  </style>

${DEFS}

${BODY}

  <path
    class="cog-mark__word"
    transform="translate(${textX} ${baseline}) scale(${round(scale)})"
    d="${WORDMARK.d}"
  />
</svg>
`;
}

// ── Emit ──────────────────────────────────────────────────────────────────

const clearance = verifyMesh();
if (!(clearance > 0.05)) {
  throw new Error(
    `the gears come within ${clearance.toFixed(4)} units of each other over a meshing ` +
      `cycle; raise PROFILE.backlash until they clear`,
  );
}

const css = readFileSync(THEME_CSS, "utf8");

writeFileSync(COMPONENT, COMPONENT_DOC.replace("MESH", clearance.toFixed(2)));
writeFileSync(LOCKUP("light"), lockup({ steps: palette(css, "\\.cog-mark"), ink: "#1f2328" }));
writeFileSync(
  LOCKUP("dark"),
  lockup({ steps: palette(css, "\\.dark \\.cog-mark"), ink: "#e6edf3" }),
);

console.log(
  `build-cog-mark: wrote the component and both lockups; ` +
    `narrowest mesh clearance ${clearance.toFixed(4)} units`,
);
