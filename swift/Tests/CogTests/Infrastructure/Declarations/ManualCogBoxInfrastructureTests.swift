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
  let weather = CogBox<Int, Int>.Manual(0)

  let here = weather[90210]
  let there = weather[10001]

  #expect(here.descriptor === weather.descriptor)
  #expect(there.descriptor === weather.descriptor)
  #expect(here.descriptor.identity == there.descriptor.identity)
}

@MainActor
@Test func `ManualCogBoxInfrastructure puts the key on the value reference`() {
  let weather = CogBox<Int, Int>.Manual(0)

  #expect(weather[90210].key == CogKey(90210))
  #expect(weather[10001].key == CogKey(10001))
  #expect(weather[90210].key == weather[90210].key)
  #expect(weather[90210].key != weather[10001].key)
}

@MainActor
@Test func `ManualCogBoxInfrastructure keeps a keyless declaration and a box apart`() {
  // Two declarations, so two descriptors, even though the keyless value reference and the
  // box's value references are the same type.
  let keyless = Cog<Int>.Manual(0)
  let box = CogBox<Int, Int>.Manual(0)

  #expect(keyless.descriptor.identity != box[0].descriptor.identity)
  #expect(keyless.key == nil)
}

@MainActor
@Test func `ManualCogBoxInfrastructure labels every key with the declaration's label`() {
  // A key is not a declaration, so it does not get a name of its own. The
  // descriptor-and-key path a cycle diagnostic prints is built from the
  // box's label plus the state's key, which is why the state keeps the key.
  let named = CogBox<Int, Int>.Manual(0, name: "weather")
  let declarationLine = UInt(#line) + 1
  let unnamed = CogBox<Int, Int>.Manual(0)

  #expect("\(named[90210].descriptor.label)" == "weather")
  #expect("\(unnamed[90210].descriptor.label)" == "\(#fileID):\(declarationLine)")
}

// MARK: - Starting values

@MainActor
@Test func `ManualCogBoxInfrastructure answers a constant starting value for any key`() {
  let box = CogBox<Int, Int>.Manual(3)

  #expect(box.descriptor.startingValue(forKey: CogKey(90210)) == 3)
  #expect(box.descriptor.startingValue(forKey: CogKey(10001)) == 3)
}

@MainActor
@Test func `ManualCogBoxInfrastructure answers a per-key starting value from the closure`() {
  let box = CogBox<Int, Int>.Manual { key in key * 2 }

  #expect(box.descriptor.startingValue(forKey: CogKey(5)) == 10)
  #expect(box.descriptor.startingValue(forKey: CogKey(6)) == 12)
}

@MainActor
@Test func `ManualCogBoxInfrastructure keeps a keyless declaration's starting value keyless`() {
  // The descriptor is generic over the value and not over a key, so the
  // keyless case is the `nil` key of the same mechanism rather than a second
  // one.
  let keyless = Cog<Int>.Manual(7)

  #expect(keyless.descriptor.startingValue(forKey: nil) == 7)
}

// MARK: - Value-reference cost

@MainActor
@Test func `ManualCogBoxInfrastructure uses the selected inline key storage`() {
  // This pins the selected descriptor-plus-inline-AnyHashable shape, not its
  // runtime allocation cost. PERF-06 owns the zero-allocation behavior proof.
  #expect(
    MemoryLayout<Cog<Int>.Manual>.size == MemoryLayout<AnyObject>.size
      + MemoryLayout<AnyHashable?>.size)
}
