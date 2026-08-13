import Cog
import Testing

private nonisolated enum Async30Error: Error, Equatable {
  case offline
}

@Test func `ASYNC-30 value and error extract only the current generation`() {
  let initialPending = CogPhase<Int>.pending(previous: .none)
  let reloadPending = CogPhase<Int>.pending(previous: .some(41))
  let success = CogPhase<Int>.success(42)
  let initialFailure = CogPhase<Int>.failure(Async30Error.offline, previous: .none)
  let reloadFailure = CogPhase<Int>.failure(Async30Error.offline, previous: .some(42))

  #expect(initialPending.value == nil)
  #expect(reloadPending.value == nil)
  #expect(success.value == 42)
  #expect(initialFailure.value == nil)
  #expect(reloadFailure.value == nil)

  #expect(initialPending.error == nil)
  #expect(reloadPending.error == nil)
  #expect(success.error == nil)
  #expect(initialFailure.error as? Async30Error == .offline)
  #expect(reloadFailure.error as? Async30Error == .offline)
}

@Test func `ASYNC-30 a reload retrying after a failure reports neither value nor error`() {
  let retryPending = CogPhase<Int>.pending(previous: .some(42))

  #expect(retryPending.value == nil)
  #expect(retryPending.error == nil)
  #expect(retryPending.latestValue == 42)
}

@Test func `ASYNC-30 loading accessors split pending by retained success`() {
  let initialPending = CogPhase<Int>.pending(previous: .none)
  let reloadPending = CogPhase<Int>.pending(previous: .some(41))
  let success = CogPhase<Int>.success(42)
  let initialFailure = CogPhase<Int>.failure(Async30Error.offline, previous: .none)
  let reloadFailure = CogPhase<Int>.failure(Async30Error.offline, previous: .some(42))

  #expect(initialPending.isInitialLoading)
  #expect(!initialPending.isReloading)
  #expect(!reloadPending.isInitialLoading)
  #expect(reloadPending.isReloading)
  #expect(!success.isInitialLoading)
  #expect(!success.isReloading)
  #expect(!initialFailure.isInitialLoading)
  #expect(!initialFailure.isReloading)
  #expect(!reloadFailure.isInitialLoading)
  #expect(!reloadFailure.isReloading)
}

@Test func `ASYNC-30 a successful nil stays distinct through value`() {
  let successNil = CogPhase<Int?>.success(nil)
  let reloadAfterNil = CogPhase<Int?>.pending(previous: .some(nil))

  if let produced = successNil.value {
    #expect(produced == nil)
  } else {
    Issue.record("A successful nil should still report a current success")
  }
  #expect(reloadAfterNil.value == nil)
  #expect(reloadAfterNil.isReloading)
}
