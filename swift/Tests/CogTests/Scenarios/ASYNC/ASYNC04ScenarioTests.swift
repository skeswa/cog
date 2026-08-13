import Cog
import Testing

private nonisolated enum Async04Error: Error {
  case offline
}

@Test func `ASYNC-04 metadata accessors describe every request state`() {
  let initialPending = CogMeta<Int>.pending(value: 0, hasSucceeded: false)
  let reloadPending = CogMeta<Int>.pending(value: 41, hasSucceeded: true)
  let success = CogMeta<Int>.success(42)
  let initialFailure = CogMeta<Int>.failure(
    Async04Error.offline,
    value: 0,
    hasSucceeded: false
  )
  let reloadFailure = CogMeta<Int>.failure(
    Async04Error.offline,
    value: 42,
    hasSucceeded: true
  )

  #expect(initialPending.value == 0)
  #expect(initialPending.isLoading)
  #expect(reloadPending.value == 41)
  #expect(reloadPending.isLoading)
  #expect(success.value == 42)
  #expect(!success.isLoading)
  #expect(initialFailure.value == 0)
  #expect(!initialFailure.isLoading)
  #expect(reloadFailure.value == 42)
  #expect(!reloadFailure.isLoading)
}

@Test func `ASYNC-04 hasSucceeded distinguishes a default nil from a successful nil`() {
  let defaultNil = CogMeta<Int?>.pending(value: nil, hasSucceeded: false)
  let successfulNil = CogMeta<Int?>.pending(value: nil, hasSucceeded: true)

  switch defaultNil {
  case .pending(value: nil, hasSucceeded: false):
    break
  default:
    Issue.record("Expected the resting nil before any success")
  }

  switch successfulNil {
  case .pending(let value, hasSucceeded: true):
    #expect(value == nil)
  default:
    Issue.record("Expected an accepted nil to remain explicit")
  }
}
