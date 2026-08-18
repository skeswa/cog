import CogLintCore
import Testing

// MARK: - LINT-04

/// Proves both evidence channels normalize qualification, generics, optionals, and `.init`.
@Test func `LINT-04 classifier recognizes normalized declaration spellings`() {
  let classifications = classify(
    """
    let temperatureCog = Cog<Int> { _ in 0 }
    let temperaturesCogs = Cog.CogBox<Int, String> { _ in { _ in 0 } }
    fileprivate let currentZipSourceCog: Cog.ManualCog<Int?> = .init(nil)
    fileprivate let reportSourceCogs: ManualCogBox<String?, Int>? = Cog.ManualCogBox(nil)
    fileprivate let optionalSourceCog: Cog.ManualCog<Int>? = .init(nil)
    let forecastCog = Cog.AsyncCog<String>(default: "") { _ in fatalError() }
    let forecastsCogs: AsyncCogBox<String, Int> = .init(default: "") { _ in fatalError() }
    """
  )

  #expect(
    classifications.map(summary) == [
      "temperatureCog:keyless:derived:direct",
      "temperaturesCogs:box:derived:direct",
      "currentZipSourceCog:keyless:writable:direct",
      "reportSourceCogs:box:writable:direct",
      "optionalSourceCog:keyless:writable:direct",
      "forecastCog:keyless:async:direct",
      "forecastsCogs:box:async:direct",
    ]
  )
}

/// Proves `.readOnly` changes access while preserving source shape and writable origin.
@Test func `LINT-04 classifier carries source facts through read-only projections`() {
  let classifications = classify(
    """
    fileprivate let currentZipSourceCog = ManualCog<Int?>(nil)
    fileprivate let reportSourceCogs = ManualCogBox<String?, Int>(nil)
    let currentZipCog = currentZipSourceCog.readOnly
    let reportCogs: Cog.CogBoxProjection<String?, Int> = reportSourceCogs.readOnly
    """
  )

  #expect(
    classifications.map(summary) == [
      "currentZipSourceCog:keyless:writable:direct",
      "reportSourceCogs:box:writable:direct",
      "currentZipCog:keyless:writable:projection",
      "reportCogs:box:writable:projection",
    ]
  )
  #expect(
    classifications.filter(\.isWritableSource).map(\.name) == [
      "currentZipSourceCog", "reportSourceCogs",
    ])
}

/// Proves type-scoped projections resolve locally without leaking names into sibling types.
@Test func `LINT-04 classifier keeps projection evidence in lexical declaration scopes`() {
  let classifications = classify(
    """
    struct WeatherState {
      fileprivate static let currentZipSourceCog = ManualCog<Int?>(nil)
      static let currentZipCog = currentZipSourceCog.readOnly
    }

    struct UnrelatedState {
      static let accidentalCog = currentZipSourceCog.readOnly
    }
    """
  )

  #expect(classifications.map(\.name) == ["currentZipSourceCog", "currentZipCog"])
}

// MARK: - LINT-05

/// Proves factories, aliases, assignments, re-exports, and unknown projections stay silent.
@Test func `LINT-05 classifier accepts its documented syntax-only evasions`() {
  let classifications = classify(
    """
    typealias Source = ManualCog<Int>
    fileprivate let currentZipSourceCog = ManualCog<Int?>(nil)
    #if DEBUG
    let currentZipSeedTargetCog = currentZipSourceCog
    #endif
    let copiedSourceCog = currentZipSourceCog
    let copiedThenProjectedCog = copiedSourceCog.readOnly
    let factorySourceCog = makeSource()
    let typedFactorySourceCog: ManualCog<Int> = makeSource()
    let aliasSourceCog = Source(0)
    let externalProjectionCog = externalSourceCog.readOnly
    let forwardProjectionCog = laterSourceCog.readOnly
    fileprivate let laterSourceCog = ManualCog(0)

    func localRuntime() {
      let localSourceCog = ManualCog(0)
      _ = localSourceCog.readOnly
    }
    """
  )

  #expect(classifications.map(\.name) == ["currentZipSourceCog", "laterSourceCog"])
}

/// Parses and classifies one source buffer through the production seam.
private func classify(_ source: String) -> [CogDeclarationClassification] {
  CogDeclarationClassifier.classify(in: CogLintParser.parse(source: source))
}

/// Renders orthogonal classifier facts compactly for exact scenario assertions.
private func summary(_ classification: CogDeclarationClassification) -> String {
  let shape = classification.shape == .keyless ? "keyless" : "box"
  let origin: String
  switch classification.origin {
  case .derived: origin = "derived"
  case .writableSource: origin = "writable"
  case .asynchronous: origin = "async"
  }
  let access = classification.access == .direct ? "direct" : "projection"
  return "\(classification.name):\(shape):\(origin):\(access)"
}
