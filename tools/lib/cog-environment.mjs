/** Environment variables that change Package.swift's resolved graph or build settings. */
export const COG_MANIFEST_SELECTOR_NAMES = Object.freeze([
  "COG_DOCC",
  "COG_SIMULATOR_BOUNDARY_ONLY",
  "COG_TEST_ARENA_SPECIALIZATION",
  "COG_TEST_CORE",
  "COG_TEST_EDGE",
  "COG_TEST_ISOLATION",
  "COG_TEST_NNBD",
  "COG_TEST_VALUE_REFERENCE_LAYOUT",
]);

/**
 * Returns an environment that resolves Cog's ordinary shipping package.
 *
 * Keeping the roster here prevents API, compile-fail, distribution, and test
 * tooling from disagreeing about which ambient selectors must be removed.
 */
export function shippingManifestEnvironment(environment, overrides = {}) {
  const result = { ...environment };
  for (const name of COG_MANIFEST_SELECTOR_NAMES) delete result[name];
  return Object.assign(result, overrides);
}
