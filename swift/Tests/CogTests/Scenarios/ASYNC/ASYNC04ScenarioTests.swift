import Cog
import Testing

private nonisolated enum Async04Error: Error {
  case offline
}

@Test func `ASYNC-04 phase accessors describe every phase`() {
  let initialPending = CogPhase<Int>.pending(previous: .none)
  let reloadPending = CogPhase<Int>.pending(previous: .some(41))
  let success = CogPhase<Int>.success(42)
  let initialFailure = CogPhase<Int>.failure(Async04Error.offline, previous: .none)
  let reloadFailure = CogPhase<Int>.failure(Async04Error.offline, previous: .some(42))

  #expect(initialPending.latestValue == nil)
  #expect(initialPending.isLoading)
  #expect(reloadPending.latestValue == 41)
  #expect(reloadPending.isLoading)
  #expect(success.latestValue == 42)
  #expect(!success.isLoading)
  #expect(initialFailure.latestValue == nil)
  #expect(!initialFailure.isLoading)
  #expect(reloadFailure.latestValue == 42)
  #expect(!reloadFailure.isLoading)
}

@Test func `ASYNC-04 previous distinguishes absence from a previous nil value`() {
  let absent = CogPhase<Int?>.pending(previous: .none)
  let presentNil = CogPhase<Int?>.pending(previous: .some(nil))

  switch absent {
  case .pending(previous: .none):
    break
  default:
    Issue.record("Expected no previous value")
  }

  switch presentNil {
  case .pending(previous: .some(let value)):
    #expect(value == nil)
  default:
    Issue.record("Expected an explicit previous nil value")
  }
}
