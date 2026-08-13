import Cog
import Testing

private nonisolated enum Async30Error: Error, Equatable {
  case offline
}

@Test func `ASYNC-30 value stays total while error describes the current generation`() {
  let initialPending = CogMeta<Int>.pending(value: 0, hasSucceeded: false)
  let reloadPending = CogMeta<Int>.pending(value: 41, hasSucceeded: true)
  let success = CogMeta<Int>.success(42)
  let initialFailure = CogMeta<Int>.failure(
    Async30Error.offline,
    value: 0,
    hasSucceeded: false
  )
  let reloadFailure = CogMeta<Int>.failure(
    Async30Error.offline,
    value: 42,
    hasSucceeded: true
  )

  #expect(initialPending.value == 0)
  #expect(reloadPending.value == 41)
  #expect(success.value == 42)
  #expect(initialFailure.value == 0)
  #expect(reloadFailure.value == 42)

  #expect(initialPending.error == nil)
  #expect(reloadPending.error == nil)
  #expect(success.error == nil)
  #expect(initialFailure.error as? Async30Error == .offline)
  #expect(reloadFailure.error as? Async30Error == .offline)
}

@Test func `ASYNC-30 a reload retrying after a failure reports neither value nor error`() {
  let retryPending = CogMeta<Int>.pending(value: 42, hasSucceeded: true)

  #expect(retryPending.value == 42)
  #expect(retryPending.error == nil)
}

@Test func `ASYNC-30 loading and success stay orthogonal`() {
  let initialPending = CogMeta<Int>.pending(value: 0, hasSucceeded: false)
  let reloadPending = CogMeta<Int>.pending(value: 41, hasSucceeded: true)
  let success = CogMeta<Int>.success(42)
  let initialFailure = CogMeta<Int>.failure(
    Async30Error.offline,
    value: 0,
    hasSucceeded: false
  )
  let reloadFailure = CogMeta<Int>.failure(
    Async30Error.offline,
    value: 42,
    hasSucceeded: true
  )

  #expect(initialPending.isLoading)
  #expect(reloadPending.isLoading)
  #expect(!success.isLoading)
  #expect(!initialFailure.isLoading)
  #expect(!reloadFailure.isLoading)

  #expect(!initialPending.hasSucceeded)
  #expect(reloadPending.hasSucceeded)
  #expect(success.hasSucceeded)
  #expect(!initialFailure.hasSucceeded)
  #expect(reloadFailure.hasSucceeded)
}

@Test func `ASYNC-30 a successful nil stays distinct through value`() {
  let successNil = CogMeta<Int?>.success(nil)
  let reloadAfterNil = CogMeta<Int?>.pending(value: nil, hasSucceeded: true)

  #expect(successNil.value == nil)
  #expect(successNil.hasSucceeded)
  #expect(reloadAfterNil.value == nil)
  #expect(reloadAfterNil.hasSucceeded)
  #expect(reloadAfterNil.isLoading)
}
