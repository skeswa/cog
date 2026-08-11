import Testing

/// The single sentinel that proves a test runner actually selected work.
///
/// Every CI test leg filters on `M0Sentinel`; the mise test wrapper (`M0-03`)
/// fails when a filter expression selects nothing, so this test is what makes
/// an empty selection distinguishable from a passing run.
@Test func `M0Sentinel selects work in every test leg`() {
  #expect(Bool(true))
}
