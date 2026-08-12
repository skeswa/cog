import CogTesting
import Testing

@testable import Cog

// Computing marks and structured paths are infrastructure in M1-15b. These
// probes own no CYCLE scenario: later behavior tasks expose the CogTesting
// diagnostic seam and prove the shipping fatalError contract in child
// processes.

// MARK: - Real read-path integration

@MainActor
@Test func `CycleDetectionInfrastructure catches a self read through the real graph`() async {
  let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
    await MainActor.run {
      let cogs = Cogtext.forTesting()
      var ref: Cog<Int>!
      ref = Cog<Int>({ c in c.get(ref) }, name: "self")
      _ = cogs.read(ref)
    }
  }

  expectCycleMessage(in: result, path: "self -> self")
}

@MainActor
@Test func `CycleDetectionInfrastructure catches a fresh multi node cycle`() async {
  let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
    await MainActor.run {
      let cogs = Cogtext.forTesting()
      var first: Cog<Int>!
      var second: Cog<Int>!
      first = Cog<Int>({ c in c.get(second) }, name: "first")
      second = Cog<Int>({ c in c.get(first) }, name: "second")
      _ = cogs.read(first)
    }
  }

  expectCycleMessage(in: result, path: "first -> second -> first")
}

@MainActor
@Test func `CycleDetectionInfrastructure catches every key through the real graph`() async {
  let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
    await MainActor.run {
      let cogs = Cogtext.forTesting()
      let holder = CycleBoxHolder()
      holder.box = CogBox<Int, String>(
        { c, key in
          c.get(holder.box[key == "home" ? "work" : "home"])
        },
        name: "weather"
      )
      _ = cogs.read(holder.box["home"])
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
        { c in c.get(closesCycle) ? c.get(second) : 1 },
        name: "first"
      )
      second = Cog<Int>({ c in c.get(first) + 1 }, name: "second")

      _ = cogs.read(second)
      cogs.commit { w in w[closesCycle] = true }
      _ = cogs.read(first)
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
  let ref = Cog<Int>({ _ in 1 }, name: "self")
  let node = cogs.derivedNode(for: ref)

  cogs.settleStack.beginComputing(node)
  defer { cogs.settleStack.endComputing(node) }

  let cycle = cogs.settleStack.cyclePath(ifEntering: node)
  #expect(node.isComputing)
  #expect(cogs.settleStack.computingCount == 1)
  #expect(cycle?.steps.count == 2)
  #expect(cycle?.steps.map(\.descriptor) == [ref.descriptor.identity, ref.descriptor.identity])
  #expect(cycle?.steps.allSatisfy { $0.key == nil } == true)
  #expect(cycle?.message == "Cog dependency cycle: self -> self.")
}

@MainActor
@Test func `CycleDetectionInfrastructure keeps only the ordered cycle suffix`() {
  let cogs = Cogtext.forTesting()
  let prefixRef = Cog<Int>({ _ in 0 }, name: "same label")
  let firstRef = Cog<Int>({ _ in 1 }, name: "same label")
  let secondRef = Cog<Int>({ _ in 2 }, name: "second")
  let prefix = cogs.derivedNode(for: prefixRef)
  let first = cogs.derivedNode(for: firstRef)
  let second = cogs.derivedNode(for: secondRef)

  cogs.settleStack.beginComputing(prefix)
  cogs.settleStack.beginComputing(first)
  cogs.settleStack.beginComputing(second)

  let cycle = cogs.settleStack.cyclePath(ifEntering: first)
  #expect(
    cycle?.steps.map(\.descriptor)
      == [firstRef, secondRef, firstRef].map { $0.descriptor.identity })
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
  let homeRef = box[Optional<Int>.none]
  let workRef = box[10001]
  let home = cogs.derivedNode(for: homeRef)
  let work = cogs.derivedNode(for: workRef)

  cogs.settleStack.beginComputing(home)
  #expect(cogs.settleStack.cyclePath(ifEntering: work) == nil)
  cogs.settleStack.beginComputing(work)

  let cycle = cogs.settleStack.cyclePath(ifEntering: home)
  #expect(cycle?.steps.map(\.descriptor).allSatisfy { $0 == box.descriptor.identity } == true)
  #expect(cycle?.steps.map(\.key) == [homeRef.key, workRef.key, homeRef.key])
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
  var ref: Cog<Int>!

  ref = Cog<Int>(
    { c in
      selectorMarks.append(cogs.derivedNode(for: ref).isComputing)
      return c.get(source)
    },
    equals: { old, new in
      equalityMarks.append(cogs.derivedNode(for: ref).isComputing)
      return old == new
    },
    name: "marked"
  )

  #expect(cogs.read(ref) == 1)
  #expect(cogs.derivedNode(for: ref).isComputing == false)
  #expect(cogs.settleStack.isComputingEmpty)

  cogs.commit { w in w[source] = 2 }
  #expect(cogs.read(ref) == 2)
  #expect(selectorMarks == [true, true])
  #expect(equalityMarks == [true])
  #expect(cogs.derivedNode(for: ref).isComputing == false)
  #expect(cogs.settleStack.isComputingEmpty)
}

@MainActor
@Test func `CycleDetectionInfrastructure stays marked while publishing a replacement`() {
  let cogs = Cogtext.forTesting()
  let source = ManualCog<Int>(1)
  var releaseMarks: [Bool] = []
  weak var publicationNode: DerivedCogNode<CyclePublicationValue>?
  let ref = Cog<CyclePublicationValue> { c in
    CyclePublicationValue(c.get(source)) {
      releaseMarks.append(publicationNode?.isComputing == true)
    }
  }
  publicationNode = cogs.derivedNode(for: ref)

  _ = cogs.read(ref)
  #expect(releaseMarks.isEmpty)

  cogs.commit { w in w[source] = 2 }
  #expect(cogs.read(ref).value == 2)

  #expect(releaseMarks == [true])
  #expect(publicationNode?.isComputing == false)
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

  let late = Cog<Int> { c in c.get(lateSource) }
  let left = Cog<Int> { c in
    leftRuns += 1
    return c.get(switcher) ? c.get(late) : 1
  }
  let right = Cog<Int> { c in
    rightRuns += 1
    return c.get(rightSource)
  }
  let root = Cog<Int> { c in
    rootRuns += 1
    return c.get(left) + c.get(right)
  }

  #expect(cogs.read(root) == 11)
  #expect(cogs.read(late) == 100)

  cogs.commit { w in
    w[switcher] = true
    w[rightSource] = 20
    w[lateSource] = 200
  }

  #expect(cogs.read(root) == 220)
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
