import CogTesting
import Testing

@testable import Cog

// Internal checks for one descriptor per box, lazy per-key storage, and keys
// retained for diagnostics. Scenario tests cover the public behavior.

// MARK: - One descriptor per box

@MainActor
@Test func `ManualCogBoxInfrastructure gives a whole box one descriptor`() {
  // Keys reuse the box's descriptor. Erasing a large key to `AnyHashable` may
  // still allocate.
  let weather = ManualCogBox<Int, Int>(0)

  let here = weather[90210]
  let there = weather[10001]

  #expect(here.descriptor === weather.descriptor)
  #expect(there.descriptor === weather.descriptor)
  #expect(here.descriptor.identity == there.descriptor.identity)
}

@MainActor
@Test func `ManualCogBoxInfrastructure puts the key on the value reference`() {
  let weather = ManualCogBox<Int, Int>(0)

  #if COG_LEG_VALUE_REFERENCE_LAYOUT_GENERIC
  let here: Int = weather[90210].key
  let there: Int = weather[10001].key
  #expect(here == 90210)
  #expect(there == 10001)
  #else
  #expect(weather[90210].key == CogKey(90210))
  #expect(weather[10001].key == CogKey(10001))
  #endif
  #expect(weather[90210].key == weather[90210].key)
  #expect(weather[90210].key != weather[10001].key)
}

@MainActor
@Test func `ManualCogBoxInfrastructure keeps a keyless declaration and a box apart`() {
  // Two declarations, so two descriptors, even though the keyless value reference and the
  // box's value references are the same type.
  let keyless = ManualCog<Int>(0)
  let box = ManualCogBox<Int, Int>(0)

  #expect(keyless.descriptor.identity != box[0].descriptor.identity)
  #expect(keyless.key == nil)
}

@MainActor
@Test func `ManualCogBoxInfrastructure labels every key with the declaration's label`() {
  // A key is not a declaration, so it does not get a name of its own. The
  // descriptor-and-key path a cycle diagnostic prints is built from the
  // box's label plus the state's key, which is why the state keeps the key.
  let named = ManualCogBox<Int, Int>(0, name: "weather")
  let declarationLine = UInt(#line) + 1
  let unnamed = ManualCogBox<Int, Int>(0)

  #expect("\(named[90210].descriptor.label)" == "weather")
  #expect("\(unnamed[90210].descriptor.label)" == "\(#fileID):\(declarationLine)")
}

// MARK: - One state per key

@MainActor
@Test func `ManualCogBoxInfrastructure gives every key its own state`() {
  let cogs = Cogs.forTesting()
  let weather = ManualCogBox<Int, Int>(0)

  #expect(cogs.manualState(for: weather[90210]) === cogs.manualState(for: weather[90210]))
  #expect(cogs.manualState(for: weather[90210]) !== cogs.manualState(for: weather[10001]))
  #expect(cogs.states.count == 2)
}

@MainActor
@Test func `ManualCogBoxInfrastructure creates a key's state only when it is used`() {
  let cogs = Cogs.forTesting()

  let weather = ManualCogBox<Int, Int>(0)
  #expect(cogs.states.isEmpty)

  // Building value references is not using them. Nothing resolves until a context is
  // asked, which is what makes a value reference safe to build inline at a call site.
  let here = weather[90210]
  let there = weather[10001]
  #expect(cogs.states.isEmpty)

  _ = cogs.peek(here)
  #expect(cogs.states.count == 1)
  #expect(
    cogs.states[CogStateIdentity(descriptor: there.descriptor.identity, key: CogKey(10001))] == nil)
}

@MainActor
@Test func `ManualCogBoxInfrastructure keeps a state's key for diagnostics`() {
  let cogs = Cogs.forTesting()
  let weather = ManualCogBox<Int, Int>(0, name: "weather")

  let state = cogs.manualState(for: weather[90210])

  #expect("\(state.label)" == "weather")
  #expect(state.key == CogKey(90210))
}

// MARK: - Starting values

@MainActor
@Test func `ManualCogBoxInfrastructure answers a constant starting value for any key`() {
  let box = ManualCogBox<Int, Int>(3)

  #expect(box.descriptor.startingValue(forKey: CogKey(90210)) == 3)
  #expect(box.descriptor.startingValue(forKey: CogKey(10001)) == 3)
}

@MainActor
@Test func `ManualCogBoxInfrastructure answers a per-key starting value from the closure`() {
  let box = ManualCogBox<Int, Int> { key in key * 2 }

  #expect(box.descriptor.startingValue(forKey: CogKey(5)) == 10)
  #expect(box.descriptor.startingValue(forKey: CogKey(6)) == 12)
}

@MainActor
@Test func `ManualCogBoxInfrastructure keeps a keyless declaration's starting value keyless`() {
  // The descriptor is generic over the value and not over a key, so the
  // keyless case is the `nil` key of the same mechanism rather than a second
  // one.
  let keyless = ManualCog<Int>(7)

  #expect(keyless.descriptor.startingValue(forKey: nil) == 7)
}

// MARK: - Value-reference cost

@MainActor
@Test func `ManualCogBoxInfrastructure builds a value reference out of two inert words of storage`()
{
  // This pins the current storage shape, not its runtime allocation cost — and
  // the shape is exactly what `COG_TEST_VALUE_REFERENCE_LAYOUT` selects, so the
  // expectation follows the layout rather than outliving it. Writing one number
  // for both would either fail under a candidate that does its job or pass
  // under one that does not.
  //
  // The gap is the measurement: a descriptor reference plus an inline
  // `AnyHashable?` is 48 bytes, and a descriptor reference plus an interned
  // `Int?` token is 17. That is the size win perf §4 sends the interned
  // candidate to find, visible here before any benchmark runs.
  #if COG_LEG_VALUE_REFERENCE_LAYOUT_INLINE
  #expect(
    MemoryLayout<ManualCog<Int>>.size == MemoryLayout<AnyObject>.size
      + MemoryLayout<AnyHashable?>.size)
  #elseif COG_LEG_VALUE_REFERENCE_LAYOUT_INTERNED
  #expect(
    MemoryLayout<ManualCog<Int>>.size == MemoryLayout<AnyObject>.size
      + MemoryLayout<Int?>.size)
  #else
  #expect(
    MemoryLayout<ManualCogBox<Int, Int>.ValueReference>.size
      == MemoryLayout<AnyObject>.size + MemoryLayout<Int>.size)
  #endif
}
