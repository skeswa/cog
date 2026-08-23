import Testing

@testable import Cog

// Internal identity and label checks. Public scenario tests do not inspect
// descriptors or graph storage.

// MARK: - Identity

@MainActor
@Test func `DescriptorInfrastructure gives every declaration its own identity`() {
  // Same type, same starting value, same label — and still two different cogs,
  // because identity is the descriptor object and nothing else.
  let left = Cog<Int>.Manual(0, name: "twin")
  let right = Cog<Int>.Manual(0, name: "twin")

  #expect(left.descriptor.identity != right.descriptor.identity)
  #expect(Set([left.descriptor.identity, right.descriptor.identity]).count == 2)
}

@MainActor
@Test func `DescriptorInfrastructure keeps a declaration's identity stable`() {
  let declared = Cog<Int>.Manual(0)
  let copied = declared
  let returned = passedThrough(declared)

  #expect(declared.descriptor.identity == declared.descriptor.identity)
  #expect(copied.descriptor.identity == declared.descriptor.identity)
  #expect(returned.descriptor.identity == declared.descriptor.identity)
}

/// Copies a value reference through a call boundary, so the test above compares identities
/// the optimizer cannot have folded into one another.
@MainActor
private func passedThrough(_ valueReference: Cog<Int>.Manual) -> Cog<Int>.Manual {
  valueReference
}

// MARK: - Labels

@MainActor
@Test func `DescriptorInfrastructure labels a named declaration with its name`() {
  let named = Cog<Int>.Manual(0, name: "current zip")

  #expect("\(named.descriptor.label)" == "current zip")
}

@MainActor
@Test func `DescriptorInfrastructure labels an unnamed declaration with its file and line`() {
  let declarationLine = UInt(#line) + 1
  let unnamed = Cog<Int>.Manual(0)

  #expect("\(unnamed.descriptor.label)" == "\(#fileID):\(declarationLine)")
}

@MainActor
@Test func `DescriptorInfrastructure prints labels without knowing the value type`() {
  // What a cycle diagnostic and the debug history log have to do: hold
  // descriptors of unrelated value types and still name and tell them apart.
  let descriptors: [any CogDescriptor] = [
    Cog<Int>.Manual(0, name: "count").descriptor,
    Cog<String>.Manual("", name: "greeting").descriptor,
  ]

  #expect(descriptors.map { "\($0.label)" } == ["count", "greeting"])
  #expect(Set(descriptors.map { $0.identity }).count == 2)
}

// MARK: - Value references

@MainActor
@Test func `DescriptorInfrastructure declares a keyless value reference bound to its descriptor`() {
  let source = Cog<Int>.Manual(0)

  #expect(source.key == nil)
}

@MainActor
@Test func `DescriptorInfrastructure builds a keyed value reference without a second descriptor`() {
  // `box[key]` builds a new value reference for the same declaration.
  let source = Cog<Int>.Manual(0)
  let keyed = Cog.Manual(descriptor: source.descriptor, key: CogKey(5))
  let sameKeyAgain = Cog.Manual(descriptor: source.descriptor, key: CogKey(5))

  #expect(keyed.descriptor.identity == source.descriptor.identity)
  #expect(keyed.key == CogKey(5))
  #expect(keyed.key == sameKeyAgain.key)
  #expect(keyed.key != CogKey(6))
}

// MARK: - Starting values

@MainActor
@Test func `DescriptorInfrastructure keeps the starting value on the declaration`() {
  let counter = Cog<Int>.Manual(7)
  let optional = Cog<String?>.Manual(nil)

  #expect(counter.descriptor.startingValue(forKey: nil) == 7)
  #expect(optional.descriptor.startingValue(forKey: nil) == nil)
}
