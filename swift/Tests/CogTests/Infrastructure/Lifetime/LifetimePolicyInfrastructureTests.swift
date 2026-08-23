import Testing

@testable import Cog

private nonisolated struct LifetimeOpaqueValue {
  let rawValue: Int
}

@MainActor
@Test func `LifetimePolicyInfrastructure manual declarations default to app lifetime`() {
  let keylessOpaque = Cog.Manual(LifetimeOpaqueValue(rawValue: 0))
  let keylessCustom = Cog.Manual(
    LifetimeOpaqueValue(rawValue: 0),
    equals: { $0.rawValue == $1.rawValue }
  )
  let keylessEquatable = Cog<Int>.Manual(0)
  let constantBox = CogBox<LifetimeOpaqueValue, Int>.Manual(
    LifetimeOpaqueValue(rawValue: 0)
  )
  let constantCustomBox = CogBox<LifetimeOpaqueValue, Int>.Manual(
    LifetimeOpaqueValue(rawValue: 0),
    equals: { $0.rawValue == $1.rawValue }
  )
  let perKeyBox = CogBox<LifetimeOpaqueValue, Int>.Manual { key in
    LifetimeOpaqueValue(rawValue: key)
  }
  let customBox = CogBox<LifetimeOpaqueValue, Int>.Manual(
    { key in LifetimeOpaqueValue(rawValue: key) },
    equals: { $0.rawValue == $1.rawValue }
  )
  let equatableBox = CogBox<Int, Int>.Manual(0)
  let perKeyEquatableBox = CogBox<Int, Int>.Manual { key in key }

  let lifetimes = [
    keylessOpaque.descriptor.lifetime,
    keylessCustom.descriptor.lifetime,
    keylessEquatable.descriptor.lifetime,
    constantBox.descriptor.lifetime,
    constantCustomBox.descriptor.lifetime,
    perKeyBox.descriptor.lifetime,
    customBox.descriptor.lifetime,
    equatableBox.descriptor.lifetime,
    perKeyEquatableBox.descriptor.lifetime,
  ]
  #expect(lifetimes.allSatisfy { $0 == .app })
}

@MainActor
@Test func `LifetimePolicyInfrastructure automatic declarations select one shared policy`() {
  let descriptorDefault = AutomaticCogDescriptor<LifetimeOpaqueValue>(
    selector: { _, _ in LifetimeOpaqueValue(rawValue: 0) },
    equals: nil,
    label: CogLabel(name: "descriptor default", fileID: #fileID, line: #line)
  )
  let keylessDefault = Cog<LifetimeOpaqueValue> { _ in LifetimeOpaqueValue(rawValue: 0) }
  let keylessCustomDefault = Cog<LifetimeOpaqueValue>(
    { _ in LifetimeOpaqueValue(rawValue: 0) },
    equals: { $0.rawValue == $1.rawValue }
  )
  let keylessEquatableDefault = Cog<Int> { _ in 0 }
  let keyedDefault = CogBox<LifetimeOpaqueValue, Int> { _, key in
    LifetimeOpaqueValue(rawValue: key)
  }
  let keyedCustomDefault = CogBox<LifetimeOpaqueValue, Int>(
    { _, key in LifetimeOpaqueValue(rawValue: key) },
    equals: { $0.rawValue == $1.rawValue }
  )
  let keyedEquatableDefault = CogBox<Int, Int> { _, key in key }

  let defaults = [
    descriptorDefault.lifetime,
    keylessDefault.descriptor.lifetime,
    keylessCustomDefault.descriptor.lifetime,
    keylessEquatableDefault.descriptor.lifetime,
    keyedDefault.descriptor.lifetime,
    keyedCustomDefault.descriptor.lifetime,
    keyedEquatableDefault.descriptor.lifetime,
  ]
  #expect(defaults.allSatisfy { $0 == .whileObserved(grace: nil) })
}
