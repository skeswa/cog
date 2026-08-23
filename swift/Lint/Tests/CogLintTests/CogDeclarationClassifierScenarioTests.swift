import CogLintCore
import Testing

// MARK: - LINT-04

/// Proves both evidence channels normalize qualification, generics, optionals, and `.init`.
@Test func `LINT-04 classifier recognizes normalized declaration spellings`() {
  let classifications = classify(
    """
    let temperatureCog = Cog<Int> { _ in 0 }
    let temperaturesCogs = Cog.CogBox<Int, String> { _ in { _ in 0 } }
    fileprivate let _currentZipCog: Cog.Cog<Int?>.Manual = .init(nil)
    fileprivate let _reportCogs: CogBox<String?, Int>.Manual? = CogBox.Manual(nil)
    fileprivate let _optionalCog: Cog<Int>.Manual? = .init(nil)
    let forecastCog = Cog.Cog<String>.Async(default: "") { _ in fatalError() }
    let forecastsCogs: CogBox<String, Int>.Async = .init(default: "") { _, _ in fatalError() }
    """
  )

  #expect(
    classifications.map(summary) == [
      "temperatureCog:keyless:automatic:direct",
      "temperaturesCogs:box:automatic:direct",
      "_currentZipCog:keyless:writable:direct",
      "_reportCogs:box:writable:direct",
      "_optionalCog:keyless:writable:direct",
      "forecastCog:keyless:async:direct",
      "forecastsCogs:box:async:direct",
    ]
  )
}

/// Proves `.readOnly` changes access while preserving source shape and writable origin.
@Test func `LINT-04 classifier carries source facts through read-only projections`() {
  let classifications = classify(
    """
    fileprivate let _currentZipCog = Cog<Int?>.Manual(nil)
    fileprivate let _reportCogs = CogBox<String?, Int>.Manual(nil)
    let currentZipCog = _currentZipCog.readOnly
    let reportCogs: Cog.CogBox<String?, Int>.Projection = _reportCogs.readOnly
    """
  )

  #expect(
    classifications.map(summary) == [
      "_currentZipCog:keyless:writable:direct",
      "_reportCogs:box:writable:direct",
      "currentZipCog:keyless:writable:projection",
      "reportCogs:box:writable:projection",
    ]
  )
  #expect(
    classifications.filter(\.isWritableSource).map(\.name) == [
      "_currentZipCog", "_reportCogs",
    ])
}

/// Proves type-scoped projections resolve locally without leaking names into sibling types.
@Test func `LINT-04 classifier keeps projection evidence in lexical declaration scopes`() {
  let classifications = classify(
    """
    struct WeatherState {
      fileprivate static let _currentZipCog = Cog<Int?>.Manual(nil)
      static let currentZipCog = _currentZipCog.readOnly
    }

    struct UnrelatedState {
      static let accidentalCog = _currentZipCog.readOnly
    }
    """
  )

  #expect(classifications.map(\.name) == ["_currentZipCog", "currentZipCog"])
}

// MARK: - LINT-05

/// Proves factories, aliases, assignments, re-exports, and unknown projections stay silent.
@Test func `LINT-05 classifier accepts its documented syntax-only evasions`() {
  let classifications = classify(
    """
    typealias Source = Cog<Int>.Manual
    fileprivate let _currentZipCog = Cog<Int?>.Manual(nil)
    #if DEBUG
    let currentZipSeedTargetCog = _currentZipCog
    #endif
    let _copiedCog = _currentZipCog
    let copiedThenProjectedCog = _copiedCog.readOnly
    let _factoryCog = makeSource()
    let _typedFactoryCog: Cog<Int>.Manual = makeSource()
    let _aliasCog = Source(0)
    let externalProjectionCog = _externalCog.readOnly
    let forwardProjectionCog = _laterCog.readOnly
    fileprivate let _laterCog = Cog.Manual(0)

    func localRuntime() {
      let _localCog = Cog.Manual(0)
      _ = _localCog.readOnly
    }
    """
  )

  #expect(classifications.map(\.name) == ["_currentZipCog", "_laterCog"])
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
  case .automatic: origin = "automatic"
  case .writableSource: origin = "writable"
  case .asynchronous: origin = "async"
  }
  let access = classification.access == .direct ? "direct" : "projection"
  return "\(classification.name):\(shape):\(origin):\(access)"
}
