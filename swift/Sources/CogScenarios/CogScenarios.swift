internal import Cog

/// Linkage marker for the `CogScenarios` target, exported as the non-API
/// `_CogScenarios` product.
///
/// The product gives tests and, later, benchmarks one home for reusable graph
/// declarations without making those fixtures part of the shipping `Cog` API.
/// The benchmark graphs and their expected recomputation counts arrive in M5;
/// until then the marker keeps target-linkage tests meaningful.
enum CogScenariosScaffolding {
  /// A stable value sentinel tests reference to prove this target was linked.
  static let marker = "CogScenarios"
}
