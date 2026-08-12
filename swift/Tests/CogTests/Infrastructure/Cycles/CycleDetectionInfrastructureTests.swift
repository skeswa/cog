import CogTesting
import Testing

@testable import Cog

// These internal checks cover computation paths. Scenario tests use the
// CogTesting diagnostic and child processes to cover public failures.

// MARK: - Real read-path integration

@MainActor
@Test func `CycleDetectionInfrastructure catches every key through the real graph`() async {
  let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
    await MainActor.run {
      let cogs = Cogtext.forTesting()
      let holder = CycleBoxHolder()
      holder.box = CogBox<Int, String>(
        { c, key in
          c[holder.box[key == "home" ? "work" : "home"]]
        },
        name: "weather"
      )
      _ = cogs.peek(holder.box["home"])
    }
  }

  expectCycleMessage(
    in: result,
    path: "weather[home] -> weather[work] -> weather[home]"
  )
}

@MainActor
@Test func `CycleDetectionInfrastructure catches a warm cycle at explicit stack entry`() async {
  let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
    await MainActor.run {
      let cogs = Cogtext.forTesting()
      let closesCycle = ManualCog<Bool>(false)
      var first: Cog<Int>!
      var second: Cog<Int>!
      first = Cog<Int>(
        { c in c[closesCycle] ? c[second] : 1 },
        name: "first"
      )
      second = Cog<Int>({ c in c[first] + 1 }, name: "second")

      _ = cogs.peek(second)
      cogs.commit { c in c[closesCycle] = true }
      _ = cogs.peek(first)
    }
  }

  // The first read captures second -> first without a cycle. Once the branch
  // flips, first reads dirty second; second's captured parent reaches the
  // already-active first through an explicit enter frame.
  expectCycleMessage(in: result, path: "first -> second -> first")
}

private func expectCycleMessage(in result: ExitTest.Result?, path: String) {
  let stderr = String(decoding: result?.standardErrorContent ?? [], as: UTF8.self)
  #expect(stderr.contains("Cog dependency cycle"), "stderr was: \(stderr)")
  #expect(stderr.contains(path), "stderr was: \(stderr)")
}

// MARK: - Structured path and lifetime probes

@MainActor
@Test func `CycleDetectionInfrastructure builds a closed self path`() {
  let cogs = Cogtext.forTesting()
  let valueReference = Cog<Int>({ _ in 1 }, name: "self")
  let state = cogs.derivedState(for: valueReference)

  cogs.settleStack.beginComputing(state)
  defer { cogs.settleStack.endComputing(state) }

  let cycle = cogs.settleStack.cyclePath(ifEntering: state)
  #expect(state.isComputing)
  #expect(cogs.settleStack.computingCount == 1)
  #expect(cycle?.steps.count == 2)
  #expect(
    cycle?.steps.map(\.descriptor) == [
      valueReference.descriptor.identity, valueReference.descriptor.identity,
    ])
  #expect(cycle?.steps.allSatisfy { $0.key == nil } == true)
  #expect(cycle?.message == "Cog dependency cycle: self -> self.")
}

@MainActor
@Test func `CycleDetectionInfrastructure keeps only the ordered cycle suffix`() {
  let cogs = Cogtext.forTesting()
  let prefixValueReference = Cog<Int>({ _ in 0 }, name: "same label")
  let firstValueReference = Cog<Int>({ _ in 1 }, name: "same label")
  let secondValueReference = Cog<Int>({ _ in 2 }, name: "second")
  let prefix = cogs.derivedState(for: prefixValueReference)
  let first = cogs.derivedState(for: firstValueReference)
  let second = cogs.derivedState(for: secondValueReference)

  cogs.settleStack.beginComputing(prefix)
  cogs.settleStack.beginComputing(first)
  cogs.settleStack.beginComputing(second)

  let cycle = cogs.settleStack.cyclePath(ifEntering: first)
  #expect(
    cycle?.steps.map(\.descriptor)
      == [firstValueReference, secondValueReference, firstValueReference].map {
        $0.descriptor.identity
      })
  #expect(cycle?.message == "Cog dependency cycle: same label -> second -> same label.")

  cogs.settleStack.endComputing(second)
  #expect(first.isComputing)
  #expect(prefix.isComputing)
  #expect(second.isComputing == false)
  cogs.settleStack.endComputing(first)
  cogs.settleStack.endComputing(prefix)

  #expect(cogs.settleStack.isComputingEmpty)
  #expect(prefix.isComputing == false)
  #expect(first.isComputing == false)
}

@MainActor
@Test func `CycleDetectionInfrastructure preserves every keyed path step`() {
  let cogs = Cogtext.forTesting()
  let box = CogBox<Int, Int?>({ _, key in key ?? -1 }, name: "weather")
  let homeValueReference = box[Optional<Int>.none]
  let workValueReference = box[10001]
  let home = cogs.derivedState(for: homeValueReference)
  let work = cogs.derivedState(for: workValueReference)

  cogs.settleStack.beginComputing(home)
  #expect(cogs.settleStack.cyclePath(ifEntering: work) == nil)
  cogs.settleStack.beginComputing(work)

  let cycle = cogs.settleStack.cyclePath(ifEntering: home)
  #expect(cycle?.steps.map(\.descriptor).allSatisfy { $0 == box.descriptor.identity } == true)
  #expect(
    cycle?.steps.map(\.key) == [
      homeValueReference.key, workValueReference.key, homeValueReference.key,
    ])
  #expect(cycle?.message == "Cog dependency cycle: weather[nil] -> weather[10001] -> weather[nil].")

  cogs.settleStack.endComputing(work)
  cogs.settleStack.endComputing(home)
  #expect(cogs.settleStack.isComputingEmpty)
}

@MainActor
@Test func `CycleDetectionInfrastructure spans selectors equality and publication`() {
  let cogs = Cogtext.forTesting()
  let source = ManualCog<Int>(1)
  var selectorMarks: [Bool] = []
  var equalityMarks: [Bool] = []
  var valueReference: Cog<Int>!

  valueReference = Cog<Int>(
    { c in
      selectorMarks.append(cogs.derivedState(for: valueReference).isComputing)
      return c[source]
    },
    equals: { old, new in
      equalityMarks.append(cogs.derivedState(for: valueReference).isComputing)
      return old == new
    },
    name: "marked"
  )

  #expect(cogs.peek(valueReference) == 1)
  #expect(cogs.derivedState(for: valueReference).isComputing == false)
  #expect(cogs.settleStack.isComputingEmpty)

  cogs.commit { c in c[source] = 2 }
  #expect(cogs.peek(valueReference) == 2)
  #expect(selectorMarks == [true, true])
  #expect(equalityMarks == [true])
  #expect(cogs.derivedState(for: valueReference).isComputing == false)
  #expect(cogs.settleStack.isComputingEmpty)
}

@MainActor
@Test func `CycleDetectionInfrastructure stays marked while publishing a replacement`() {
  let cogs = Cogtext.forTesting()
  let source = ManualCog<Int>(1)
  var releaseMarks: [Bool] = []
  weak var publicationState: DerivedCogState<CyclePublicationValue>?
  let valueReference = Cog<CyclePublicationValue> { c in
    CyclePublicationValue(c[source]) {
      releaseMarks.append(publicationState?.isComputing == true)
    }
  }
  publicationState = cogs.derivedState(for: valueReference)

  _ = cogs.peek(valueReference)
  #expect(releaseMarks.isEmpty)

  cogs.commit { c in c[source] = 2 }
  #expect(cogs.peek(valueReference).value == 2)

  #expect(releaseMarks == [true])
  #expect(publicationState?.isComputing == false)
  #expect(cogs.settleStack.isComputingEmpty)
}

@MainActor
@Test func `CycleDetectionInfrastructure nested settlement preserves outer frames`() {
  let cogs = Cogtext.forTesting()
  let switcher = ManualCog<Bool>(false)
  let rightSource = ManualCog<Int>(10)
  let lateSource = ManualCog<Int>(100)
  var leftRuns = 0
  var rightRuns = 0
  var rootRuns = 0

  let late = Cog<Int> { c in c[lateSource] }
  let left = Cog<Int> { c in
    leftRuns += 1
    return c[switcher] ? c[late] : 1
  }
  let right = Cog<Int> { c in
    rightRuns += 1
    return c[rightSource]
  }
  let root = Cog<Int> { c in
    rootRuns += 1
    return c[left] + c[right]
  }

  #expect(cogs.peek(root) == 11)
  #expect(cogs.peek(late) == 100)

  cogs.commit { c in
    c[switcher] = true
    c[rightSource] = 20
    c[lateSource] = 200
  }

  #expect(cogs.peek(root) == 220)
  #expect(leftRuns == 2)
  #expect(rightRuns == 2)
  #expect(rootRuns == 2)
  #expect(cogs.settleStack.isEmpty)
  #expect(cogs.settleStack.isComputingEmpty)
}

@MainActor
private final class CyclePublicationValue {
  let value: Int
  private let onDeinit: @MainActor () -> Void

  init(_ value: Int, onDeinit: @escaping @MainActor () -> Void) {
    self.value = value
    self.onDeinit = onDeinit
  }

  isolated deinit {
    onDeinit()
  }
}

@MainActor
private final class CycleBoxHolder {
  var box: CogBox<Int, String>!
}
