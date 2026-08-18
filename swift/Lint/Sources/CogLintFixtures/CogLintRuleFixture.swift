import CogLintCore

/// The prose generated around one rule's executable example corpus.
///
/// Keeping the violation, rationale, and repair beside the examples gives a
/// rule one authoritative teaching record. The checked-in DocC article is a
/// rendered product of this value rather than a second source of truth.
package struct CogLintRuleDocumentation: Equatable, Sendable {
  /// A direct statement of the source shape that the rule rejects.
  package let violation: String

  /// Why the convention matters to Cog's state and API guarantees.
  package let rationale: String

  /// The conforming rewrite a reader should make after seeing a diagnostic.
  package let repair: String

  /// Creates the complete prose contract for one generated article.
  package init(violation: String, rationale: String, repair: String) {
    self.violation = violation
    self.rationale = rationale
    self.repair = repair
  }
}

/// A documented Swift snippet used by one rule's executable specification.
///
/// The name and explanation become DocC prose, while `source` is passed
/// byte-for-byte to the parser. Keeping all three together prevents a rule's
/// test examples and teaching examples from becoming separate inventories.
package struct CogLintFixtureExample: Equatable, Sendable {
  /// A short heading that identifies the source shape under test.
  package let name: String

  /// Why this source should trigger, conform, or evade the syntax-only rule.
  package let explanation: String

  /// The complete Swift source buffer parsed by the fixture harness.
  package let source: String

  /// Creates one named, explained source example.
  package init(name: String, explanation: String, source: String) {
    self.name = name
    self.explanation = explanation
    self.source = source
  }
}

/// A one-based line and UTF-8 column expected from a fixture rule.
package struct CogLintFixturePosition: Equatable, Sendable {
  /// The one-based physical source line.
  package let line: Int

  /// The one-based UTF-8 byte column within `line`.
  package let column: Int

  /// Creates an exact position expectation.
  package init(line: Int, column: Int) {
    self.line = line
    self.column = column
  }
}

/// A source example that must produce violations at exact positions.
package struct CogLintTriggeringExample: Equatable, Sendable {
  /// The prose and Swift buffer shared with generated documentation.
  package let example: CogLintFixtureExample

  /// Every expected violation position, in deterministic report order.
  package let positions: [CogLintFixturePosition]

  /// Creates a triggering example and its complete position oracle.
  package init(example: CogLintFixtureExample, positions: [CogLintFixturePosition]) {
    self.example = example
    self.positions = positions
  }
}

/// The complete executable and documented corpus for one rule.
///
/// Conforming examples and accepted evasions are deliberately separate. Both
/// must stay clean, but only the latter records a known boundary of the v1
/// syntax-only analysis instead of promising that the source is idiomatic.
package struct CogLintRuleFixture: Sendable {
  /// The rule executed against every source example.
  package let rule: any CogLintRule

  /// The non-example prose rendered into the rule's DocC article.
  package let documentation: CogLintRuleDocumentation

  /// The explicit target role supplied while executing this corpus.
  package let targetRole: CogLintTargetRole

  /// Examples that must report at the listed exact positions.
  package let triggering: [CogLintTriggeringExample]

  /// Idiomatic examples that must produce no violations.
  package let nonTriggering: [CogLintFixtureExample]

  /// Documented syntax-only misses that must remain accepted in v1.
  package let acceptedEvasions: [CogLintFixtureExample]

  /// Creates one rule corpus without hiding empty or malformed categories.
  ///
  /// Structural validity belongs to the harness so tests can construct broken
  /// fixtures and prove those failures are diagnosed instead of trapped.
  package init(
    rule: any CogLintRule,
    documentation: CogLintRuleDocumentation,
    targetRole: CogLintTargetRole = .production,
    triggering: [CogLintTriggeringExample],
    nonTriggering: [CogLintFixtureExample],
    acceptedEvasions: [CogLintFixtureExample]
  ) {
    self.rule = rule
    self.documentation = documentation
    self.targetRole = targetRole
    self.triggering = triggering
    self.nonTriggering = nonTriggering
    self.acceptedEvasions = acceptedEvasions
  }
}
