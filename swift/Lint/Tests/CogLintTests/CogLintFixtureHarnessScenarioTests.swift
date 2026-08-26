import CogLintCore
import CogLintFixtures
import Foundation
import SwiftSyntax
import Testing

// MARK: - LINT-02

/// Proves that every semantic category is required and a valid corpus stays clean.
@Test func `LINT-02 fixture harness validates all categories and exact positions`() {
  #expect(CogLintFixtureHarness.failures(in: fixture()).isEmpty)

  let emptyCategories = CogLintRuleFixture(
    rule: FixtureSentinelRule(),
    documentation: documentation(),
    triggering: [],
    nonTriggering: [],
    acceptedEvasions: []
  )
  #expect(
    CogLintFixtureHarness.failures(in: emptyCategories).map(\.description) == [
      "fixture-sentinel has no triggering examples",
      "fixture-sentinel has no non-triggering examples",
      "fixture-sentinel has no accepted evasions",
    ]
  )
}

/// Proves every enabled rule carries an executable specification, and no more.
///
/// The two registries are written by hand in separate files, so a rule can be
/// enabled for consumers while its corpus is forgotten — which would also skip
/// its generated article, since the generator walks the fixture registry. This
/// compares the two by slug so neither list can quietly outgrow the other.
@Test func `LINT-02 every registered rule has exactly one fixture corpus`() {
  let enabled = CogLintRuleRegistry.all.map(\.slug).sorted()
  let specified = CogLintFixtureRegistry.all.map(\.rule.slug).sorted()

  #expect(enabled == specified)
  #expect(Set(specified).count == specified.count)
}

/// Proves that exact one-based diagnostic positions are executable fixture data.
@Test func `LINT-02 fixture harness fails when a diagnostic position drifts`() {
  let failures = CogLintFixtureHarness.failures(
    in: fixture(expectedPosition: CogLintFixturePosition(line: 1, column: 6))
  )

  #expect(
    failures.map(\.description) == [
      "fixture-sentinel triggering example \u{201c}Bad declaration\u{201d} expected positions 1:6; got 1:5"
    ]
  )
}

/// Proves that conforming examples and deliberate evasions must both stay clean.
@Test func `LINT-02 fixture harness rejects findings in either clean category`() {
  let nonTriggeringFailures = CogLintFixtureHarness.failures(
    in: fixture(nonTriggeringSource: "let badName = 0\n")
  )
  #expect(
    nonTriggeringFailures.map(\.description) == [
      "fixture-sentinel non-triggering \u{201c}Conforming declaration\u{201d} expected no diagnostics; got 1:5"
    ]
  )

  let evasionFailures = CogLintFixtureHarness.failures(
    in: fixture(acceptedEvasionSource: "let badName = makeState()\n")
  )
  #expect(
    evasionFailures.map(\.description) == [
      "fixture-sentinel accepted evasion \u{201c}Factory result\u{201d} expected no diagnostics; got 1:5"
    ]
  )
}

/// Proves that the documentation fragment is a deterministic view of the corpus.
@Test func `LINT-02 fixture corpus renders the canonical DocC example fragment`() {
  let fragment = CogLintFixtureHarness.docCExampleFragment(for: fixture())

  #expect(
    fragment == """
      <!-- Generated from the fixture-sentinel CogLint fixture corpus; do not edit. -->

      ## Triggering examples

      ### Bad declaration

      The sentinel identifier stands in for a rule violation.

      Expected diagnostic positions: 1:5.

      ```swift
      let badName = 0
      ```

      ## Non-triggering examples

      ### Conforming declaration

      A different identifier demonstrates an ordinary clean example.

      ```swift
      let weatherCog = 0
      ```

      ## Accepted evasions

      ### Factory result

      The sentinel deliberately does not follow values returned by factories.

      ```swift
      let madeByFactory = makeState()
      ```

      """
      + "\n"
  )
}

/// A tiny token rule that tests the fixture machinery without preempting a v1 rule task.
private struct FixtureSentinelRule: CogLintRule {
  /// The test-only slug rendered in failures and the generated fragment.
  let slug = "fixture-sentinel"

  /// The inert test URL that proves fixtures do not infer production article routes.
  let helpURL = URL(string: "https://example.invalid/fixture-sentinel")!

  /// Reports the exact token spelling reserved as the sentinel violation.
  func violations(
    in source: SourceFileSyntax,
    context _: CogLintRuleContext
  ) -> [CogLintViolation] {
    source.tokens(viewMode: .sourceAccurate).compactMap { token in
      guard token.text == "badName" else { return nil }
      return CogLintViolation(message: "sentinel violation", at: token)
    }
  }
}

/// Builds the shared sentinel corpus, optionally with a deliberately drifting position.
private func fixture(
  expectedPosition: CogLintFixturePosition = CogLintFixturePosition(line: 1, column: 5),
  nonTriggeringSource: String = "let weatherCog = 0\n",
  acceptedEvasionSource: String = "let madeByFactory = makeState()\n"
) -> CogLintRuleFixture {
  CogLintRuleFixture(
    rule: FixtureSentinelRule(),
    documentation: documentation(),
    triggering: [
      CogLintTriggeringExample(
        example: CogLintFixtureExample(
          name: "Bad declaration",
          explanation: "The sentinel identifier stands in for a rule violation.",
          source: "let badName = 0\n"
        ),
        positions: [expectedPosition]
      )
    ],
    nonTriggering: [
      CogLintFixtureExample(
        name: "Conforming declaration",
        explanation: "A different identifier demonstrates an ordinary clean example.",
        source: nonTriggeringSource
      )
    ],
    acceptedEvasions: [
      CogLintFixtureExample(
        name: "Factory result",
        explanation: "The sentinel deliberately does not follow values returned by factories.",
        source: acceptedEvasionSource
      )
    ]
  )
}

/// Supplies complete inert article prose for the fixture-harness sentinel.
private func documentation() -> CogLintRuleDocumentation {
  CogLintRuleDocumentation(
    violation: "The sentinel rejects its reserved identifier.",
    rationale: "The synthetic rule exercises the shared documentation machinery.",
    repair: "Use the conforming sentinel identifier instead."
  )
}
