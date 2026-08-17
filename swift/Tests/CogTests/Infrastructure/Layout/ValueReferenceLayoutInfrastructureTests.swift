import Cog
import CogTesting
import Foundation
import Testing

// How a keyed value reference physically carries its key is a build-time
// choice, selected by `COG_TEST_VALUE_REFERENCE_LAYOUT` and lowered by
// `Package.swift` into a define on the library (perf §4, §9). Nothing about
// that choice is visible in a passing run, so its worst failure is the same
// silent one LEG-02 closes for the isolation matrix: if the manifest stopped
// reading the environment, every candidate would compile identically and every
// candidate would still go green.
//
// Two independent comparisons close it, and this seam needs both because the
// layout is a *library* setting selected by a *test* runner:
//
//   1. the environment the runner asked for, against the define the manifest
//      mirrored into this test target — this catches a manifest that ignores
//      the environment; and
//   2. that define, against the layout the **library** reports having been
//      compiled with — this catches a manifest that mirrors the variable into
//      the tests but forgets to pass it to the library, which would leave the
//      whole matrix measuring one layout under several names.
//
// Comparison 2 is the one that matters here and the one LEG-02 has no analogue
// for: the isolation legs only ever change the test targets, while this changes
// the code under test.

#if COG_LEG_VALUE_REFERENCE_LAYOUT_INLINE && COG_LEG_VALUE_REFERENCE_LAYOUT_INTERNED
#error("Package.swift defined two value-reference layouts at once")
#endif
#if !COG_LEG_VALUE_REFERENCE_LAYOUT_INLINE && !COG_LEG_VALUE_REFERENCE_LAYOUT_INTERNED
#error("Package.swift defined no value-reference layout for the test targets")
#endif

/// The layout the manifest mirrored into this target, in the spelling
/// `COG_TEST_VALUE_REFERENCE_LAYOUT` uses.
///
/// `M5-09c` adds its case here alongside the guards above, which are what make
/// a missing or doubled define a build failure rather than a wrong string.
private let compiledValueReferenceLayout: String = {
  #if COG_LEG_VALUE_REFERENCE_LAYOUT_INLINE
  "inline"
  #else
  "interned"
  #endif
}()

@MainActor
@Test
func `ValueReferenceLayoutInfrastructure compiles the layout the environment selected`() {
  // Unset means `inline`, the correctness core's layout, exactly as the
  // manifest reads it — so an ordinary `mise run test` exercises the default
  // rather than skipping this check.
  let requested =
    ProcessInfo.processInfo.environment["COG_TEST_VALUE_REFERENCE_LAYOUT"] ?? "inline"

  #expect(compiledValueReferenceLayout == requested)
}

@MainActor
@Test
func `ValueReferenceLayoutInfrastructure builds the library with the same layout`() {
  // The library, not this target. A manifest that mirrored the variable into
  // the tests and forgot the library would pass the check above and fail here,
  // which is the whole reason the library reports its own layout.
  #expect(Cogs.valueReferenceLayoutName == compiledValueReferenceLayout)
}
