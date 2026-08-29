#!/usr/bin/env node

// Keeps the consumer tutorial executable in shape. The VitePress guide owns
// the filename-labelled walkthrough; DocC repeats the essential snippets for
// API readers. These checks hold the two copies together and reject the
// production/test boundary mistakes that make a first-run guide fail only
// after a reader has copied it into an app.

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { join } from "node:path";

const REPO_ROOT = fileURLToPath(new URL("..", import.meta.url));
const GUIDE_PATH = "docs/swift/getting-started.md";
const INSTALL_PATH = "docs/swift/installation.md";
const DOCC_PATH = "swift/Sources/Cog/Cog.docc/GettingStarted.md";

const guide = read(GUIDE_PATH);
const installation = read(INSTALL_PATH);
const docc = read(DOCC_PATH);

const guideBlocks = swiftBlocks(guide);
const doccBlocks = swiftBlocks(docc);

const state = namedGuideBlock("ForecastState+Cogs.swift");
const app = namedGuideBlock("ForecastApp.swift", 0);
const view = namedGuideBlock("Dashboard.swift");
const test = namedGuideBlock("ForecastStateTests.swift");
const mechanism = namedGuideBlock("ForecastState+Mechanisms.swift");

for (const [label, source] of [
  ["state layer", state],
  ["app entry point", app],
  ["dashboard", view],
  ["state test", test],
  ["mechanism", mechanism],
]) {
  if (!doccBlocks.some((block) => block.source === source)) {
    fail(`DocC does not carry the VitePress ${label} snippet verbatim`);
  }
}

requireIncludes(state, "extension CogOps {", "state operation surface");
requireEqual(
  state.match(/^@MainActor$/gmu)?.length ?? 0,
  3,
  "explicit MainActor state declaration count",
);
rejectIncludes(state, "extension Cogs {", "runtime-specific operation surface");
rejectPattern(guide, /\bcogs\.(?:turn|refresh)\s*\(/u, "receiver-qualified primitive");

requireIncludes(test, "@testable import Forecast", "test app-module import");
requireIncludes(test, "cogs.warmUp()", "test domain operation");
rejectIncludes(test, "_temperatureCog", "test access to the private source");
rejectPattern(test, /\b(?:turn|refresh)\s*\(/u, "test primitive shortcut");

requireIncludes(guide, "It initially shows **60°**", "initial run checkpoint");
requireIncludes(guide, "it changes to **70°**", "interaction run checkpoint");
rejectIncludes(guide, "mise run", "repository-only command in the consumer guide");
rejectIncludes(guide, "x-release-please", "release marker in the conceptual guide");

for (const [path, source] of [
  [INSTALL_PATH, installation],
  [DOCC_PATH, docc],
]) {
  for (const block of swiftBlocks(source)) {
    if (block.source.includes("x-release-please")) {
      fail(`${path} exposes a Release Please marker inside a Swift code block`);
    }
  }
}

console.log("check-getting-started: VitePress and DocC tutorial contracts passed");

/** Reads one repository-relative UTF-8 file. */
function read(path) {
  return readFileSync(join(REPO_ROOT, path), "utf8");
}

/** Returns every Swift code block and its optional VitePress filename. */
function swiftBlocks(source) {
  return [...source.matchAll(/^```swift(?: \[([^\]]+)\])?\n([\s\S]*?)^```$/gmu)].map((match) => ({
    name: match[1] ?? null,
    source: match[2].trimEnd(),
  }));
}

/** Selects one filename-labelled guide block, accounting for deliberate repeats. */
function namedGuideBlock(name, occurrence = 0) {
  const matches = guideBlocks.filter((block) => block.name === name);
  const block = matches[occurrence];
  if (block === undefined) {
    fail(`${GUIDE_PATH} has no ${JSON.stringify(name)} block at occurrence ${occurrence}`);
  }
  return block.source;
}

/** Requires one exact tutorial fragment. */
function requireIncludes(source, fragment, label) {
  if (!source.includes(fragment)) fail(`${label} is missing`);
}

/** Rejects one exact tutorial fragment. */
function rejectIncludes(source, fragment, label) {
  if (source.includes(fragment)) fail(`${label} is present`);
}

/** Rejects a tutorial pattern. */
function rejectPattern(source, pattern, label) {
  if (pattern.test(source)) fail(`${label} is present`);
}

/** Requires one tutorial count or value. */
function requireEqual(actual, expected, label) {
  if (actual !== expected) fail(`${label} is ${actual}, expected ${expected}`);
}

/** Reports one tutorial-contract failure. */
function fail(message) {
  console.error(`error: check-getting-started: ${message}`);
  process.exit(1);
}
