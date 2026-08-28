// The one parser of the scenario ledger, `docs/swift/impl/scenarios.md`.
//
// The ledger is the promised-behavior record: every stable scenario ID lives
// there as a `- **ID.**` bullet, optionally annotated with a proof mode such
// as `(Proof: compile-fail.)`. Two checkers consume this parse — the
// compile-fail runner validates that its fixtures own the right proof modes,
// and the scenario-ledger checker crosses every live ID against the test
// sources — so the bullet grammar and the proof-mode vocabulary have exactly
// one implementation here.

import { existsSync, readFileSync } from "node:fs";

/**
 * Every proof mode the ledger's "How to use this document" section names.
 *
 * Unit tests are the default and carry no mark. The checker maps each mode to
 * the place its proof must exist; an unknown mode in the ledger is a spelling
 * error this list makes detectable.
 */
export const KNOWN_PROOF_MODES = new Set([
  "compile-fail",
  "exit test",
  "release configuration",
  "release absence",
  "simulator",
  "floor runtime",
  "suite",
  "benchmark",
]);

/** Matches one scenario bullet and captures its stable ID. */
const BULLET = /^-\s+\*\*([A-Z][A-Z0-9]*-\d+[a-z]?)\.\*\*/gm;

/** Matches one proof annotation inside a bullet's body. */
const PROOF = /\(Proof:\s*([^)]*?)\.?\)/g;

/**
 * Parses the ledger into its live scenario entries.
 *
 * Each entry maps a stable ID to the family prefix before its dash, the
 * bullet's full body text (through the start of the next bullet), the set of
 * proof-mode annotations found in that body, and whether the bullet carries a
 * `_Pending_` note. Returns `null` when the ledger is missing or unreadable,
 * so a caller chooses between downgrading and failing loudly.
 *
 * @param {string} scenariosPath Absolute path of `scenarios.md`.
 * @returns {Map<string, {family: string, body: string, proofs: Set<string>,
 *   pending: boolean}> | null}
 */
export function readScenarioLedger(scenariosPath) {
  if (!existsSync(scenariosPath)) return null;
  let source;
  try {
    source = readFileSync(scenariosPath, "utf8");
  } catch {
    return null;
  }

  const starts = [];
  for (const match of source.matchAll(BULLET)) {
    starts.push({ id: match[1], index: match.index });
  }

  const entries = new Map();
  for (let index = 0; index < starts.length; index += 1) {
    const end = index + 1 < starts.length ? starts[index + 1].index : source.length;
    const body = source.slice(starts[index].index, end);
    const proofs = new Set();
    for (const proof of body.matchAll(PROOF)) {
      proofs.add(proof[1].trim().toLowerCase());
    }
    entries.set(starts[index].id, {
      family: starts[index].id.slice(0, starts[index].id.indexOf("-")),
      body,
      proofs,
      pending: body.includes("_Pending_"),
    });
  }
  return entries.size === 0 ? null : entries;
}
