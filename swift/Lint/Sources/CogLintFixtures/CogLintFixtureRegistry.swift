/// The single fixture inventory consumed by rule tests and DocC generation.
package enum CogLintFixtureRegistry {
  /// Every production rule fixture in stable rule-registration order.
  package static let all: [CogLintRuleFixture] = [
    cogDeclarationSuffix,
    noCogsInViewInit,
    primitivesOnlyInOps,
    initialStateInMechanism,
    manualCogPrivate,
    noMultiReadCogsHelper,
  ]
}
