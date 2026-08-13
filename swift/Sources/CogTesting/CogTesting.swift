internal import Cog

/// Linkage marker for the `CogTesting` library.
///
/// Test-only APIs live as public extensions in the neighboring files so apps
/// importing only `Cog` cannot see them. This internal marker remains solely
/// for the package's target-linkage sentinel.
enum CogTestingScaffolding {
  /// A stable value sentinel tests reference to prove this target was linked.
  static let marker = "CogTesting"
}
