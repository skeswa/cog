internal import Cog
import CogScenarios
import CogTesting

/// The benchmark package's entry point.
///
/// A shell today. `M5-05c` replaces this body with the pinned benchmark
/// harness once `M5-05ba` and `M5-05bb` have verified what to pin; until then
/// it exists to prove the wiring end to end — that a separate package can
/// reach `Cog`, `CogTesting`, and the shared `_CogScenarios` graphs, build in
/// release, and run one of them.
///
/// Running a scenario here rather than printing a greeting is deliberate. The
/// thing that has to keep working is that benchmarks and `CogScenarioTests`
/// drive the *same* graphs, so the smoke test is that a scenario runs and
/// reports the count its shape requires.
@main
struct CogBenchmarks {
  /// Runs each shared scenario once and reports what it cost.
  ///
  /// Every scenario gets a fresh isolated context: declarations create their
  /// state lazily per context, so a reused one would start warm and undercount.
  static func main() {
    for scenario in smokeScenarios {
      let result = scenario.run(in: Cogs.forTesting())
      let verdict = result.isExact ? "exact" : "MISMATCH"
      print(
        "\(result.name) [\(result.layout.rawValue)]: "
          + "\(result.actualRuns)/\(result.expectedRuns) runs (\(verdict)), "
          + "value \(result.finalValue)"
      )
    }
  }

  /// One small instance of each ported shape.
  ///
  /// Small on purpose: this is a wiring check, not a measurement, and a
  /// measurement taken here would have no pinned environment behind it.
  private static var smokeScenarios: [CogScenario] {
    [
      .kairoDiamond(width: 5, turns: 10),
      .kairoDeep(depth: 50, turns: 10),
      .kairoBroad(width: 50, turns: 10),
      .kairoUnstable(turns: 10),
      .dynamicSweep(width: 10, layers: 5, sourcesPerNode: 2, turns: 10),
      .cellxLattice(layers: 100),
      .keyedDiamond(keys: 10, width: 5, turns: 10),
      .keyChurn(window: 10, turns: 10),
    ]
  }
}
