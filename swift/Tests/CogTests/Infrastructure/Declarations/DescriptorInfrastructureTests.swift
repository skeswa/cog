import Testing

@testable import Cog

// `M1-01a` is infrastructure: it greens no scenario in scenarios.md. It puts
// the naming layer under everything M1 builds next — descriptor-plus-key state
// storage (`M1-01b`), boxes and allocation-free keyed value references (`M1-02`), and the
// labels the cycle diagnostic and debug history print (`M1-31b`, which owns
// DECL-10 and DECL-11). These tests therefore assert the seam itself, and
// reach through `@testable` to do it: descriptors and labels are internal on
// purpose, because a public value reference must never expose the graph's storage.
//
// Every test states `@MainActor` rather than relying on a default, so it says
// the same thing in the nonisolated legs of the isolation matrix as in the
// MainActor ones (§7).

// MARK: - Identity

@MainActor
@Test func `DescriptorInfrastructure gives every declaration its own identity`() {
  // Same type, same starting value, same label — and still two different cogs,
  // because identity is the descriptor object and nothing else.
  let left = ManualCog<Int>(0, name: "twin")
  let right = ManualCog<Int>(0, name: "twin")

  #expect(left.descriptor.identity != right.descriptor.identity)
  #expect(Set([left.descriptor.identity, right.descriptor.identity]).count == 2)
}

@MainActor
@Test func `DescriptorInfrastructure keeps a declaration's identity stable`() {
  let declared = ManualCog<Int>(0)
  let copied = declared
  let returned = passedThrough(declared)

  #expect(declared.descriptor.identity == declared.descriptor.identity)
  #expect(copied.descriptor.identity == declared.descriptor.identity)
  #expect(returned.descriptor.identity == declared.descriptor.identity)
}

/// Copies a value reference through a call boundary, so the test above compares identities
/// the optimizer cannot have folded into one another.
@MainActor
private func passedThrough(_ valueReference: ManualCog<Int>) -> ManualCog<Int> {
  valueReference
}

// MARK: - Labels

@MainActor
@Test func `DescriptorInfrastructure labels a named declaration with its name`() {
  let named = ManualCog<Int>(0, name: "current zip")

  #expect("\(named.descriptor.label)" == "current zip")
}

@MainActor
@Test func `DescriptorInfrastructure labels an unnamed declaration with its file and line`() {
  let declarationLine = UInt(#line) + 1
  let unnamed = ManualCog<Int>(0)

  #expect("\(unnamed.descriptor.label)" == "\(#fileID):\(declarationLine)")
}

@MainActor
@Test func `DescriptorInfrastructure prints labels without knowing the value type`() {
  // What a cycle diagnostic and the debug history log have to do: hold
  // descriptors of unrelated value types and still name and tell them apart.
  let descriptors: [any CogDescriptor] = [
    ManualCog<Int>(0, name: "count").descriptor,
    ManualCog<String>("", name: "greeting").descriptor,
  ]

  #expect(descriptors.map { "\($0.label)" } == ["count", "greeting"])
  #expect(Set(descriptors.map { $0.identity }).count == 2)
}

// MARK: - Value references

@MainActor
@Test func `DescriptorInfrastructure declares a keyless value reference bound to its descriptor`() {
  let source = ManualCog<Int>(0)

  #expect(source.key == nil)
}

@MainActor
@Test func `DescriptorInfrastructure builds a keyed value reference without a second descriptor`() {
  // The seam `box[key]` uses in M1-02: a new value reference, the same declaration.
  let source = ManualCog<Int>(0)
  let keyed = ManualCog(descriptor: source.descriptor, key: 5)
  let sameKeyAgain = ManualCog(descriptor: source.descriptor, key: 5)

  #expect(keyed.descriptor.identity == source.descriptor.identity)
  #expect(keyed.key == AnyHashable(5))
  #expect(keyed.key == sameKeyAgain.key)
  #expect(keyed.key != AnyHashable(6))
}

// MARK: - Starting values

@MainActor
@Test func `DescriptorInfrastructure keeps the starting value on the declaration`() {
  let counter = ManualCog<Int>(7)
  let optional = ManualCog<String?>(nil)

  #expect(counter.descriptor.startingValue(forKey: nil) == 7)
  #expect(optional.descriptor.startingValue(forKey: nil) == nil)
}
