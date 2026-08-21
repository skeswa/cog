import CogStorefront
import Foundation

/// How one launch of the Storefront benchmark application was configured.
///
/// Everything a measured run needs to vary is a **launch argument** rather than
/// a build flag, and that is a deliberate choice with two reasons behind it.
///
/// The first is that a build flag would change the binary. `XCTApplicationLaunchMetric`
/// measures the app that the UI test suite launches, so a benchmark build and
/// an ordinary build must be the same optimized image; otherwise the launch
/// number describes a binary nobody ships. Launch arguments are read after the
/// dynamic linker has already done its work, so two runs of one Release build
/// can differ in workload size and in whether the benchmark overlay exists
/// without differing in a single compiled instruction.
///
/// The second is that `XCUIApplication.launchArguments` is the only channel a
/// UI test has into a process it does not compile against. The UI-test bundle
/// deliberately links neither the application nor `CogStorefront`, so a
/// `#if BENCHMARK` symbol would be invisible to it.
///
/// Parsing is done once, at first use of ``current``, and the result is
/// immutable for the life of the process.
struct StorefrontLaunchOptions {
  /// The launch argument that selects the workload profile.
  ///
  /// Spelled with a leading dash and followed by a separate value argument, so
  /// `UserDefaults`'s `NSArgumentDomain` also parses it — which keeps the same
  /// spelling usable from an Xcode scheme's argument list.
  static let profileArgument = "-cog-storefront-profile"

  /// The launch argument that reveals the benchmark control overlay.
  static let benchmarkControlsArgument = "-cog-storefront-benchmark-controls"

  /// The workload this launch serves.
  let profile: StorefrontProfile

  /// Whether the benchmark control overlay is part of the interface.
  ///
  /// False for every ordinary launch. The overlay drives inventory bursts and
  /// resets session state, which are things a shopper must never be able to do
  /// and a UI test must be able to do exactly.
  let showsBenchmarkControls: Bool

  /// This process's options, parsed once from its actual arguments.
  static let current = StorefrontLaunchOptions(arguments: ProcessInfo.processInfo.arguments)

  /// Parses options out of one argument vector.
  ///
  /// Unknown arguments are ignored, because the test runner, the simulator, and
  /// Xcode all add their own. An unrecognized profile name falls back to
  /// ``StorefrontProfile/smoke`` rather than trapping: a mistyped argument that
  /// took the whole application down would turn a measurement mistake into a
  /// launch failure, and the profile the app actually ran is visible in the
  /// interface.
  ///
  /// - Parameter arguments: The process argument vector, including argv[0].
  init(arguments: [String]) {
    var parsedProfile = StorefrontProfile.smoke
    if let index = arguments.firstIndex(of: Self.profileArgument),
      index + 1 < arguments.count,
      let named = StorefrontProfile.named(arguments[index + 1])
    {
      parsedProfile = named
    }
    profile = parsedProfile
    showsBenchmarkControls = arguments.contains(Self.benchmarkControlsArgument)
  }
}
