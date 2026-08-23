import Cog
import CogTesting
import Testing
import os

@MainActor private let _readingCog = Cog<Int>.Manual(0, name: "reading")

@MainActor extension CogOps {
  fileprivate func recordReading(_ value: Int) {
    turn { c in c[_readingCog] = value }
  }
}

/// A delegate-style engine that calls back from wherever it happens to be.
///
/// This stands in for the SDKs mechanisms actually wrap — a socket, a location
/// manager, a sensor — which deliver on their own executor and know nothing
/// about Cog. The engine holds the callback strongly, which is exactly why the
/// callback must not hold the controller.
private nonisolated final class SensorEngine: @unchecked Sendable {
  private let onReading: @Sendable (Int) -> Void

  init(onReading: @escaping @Sendable (Int) -> Void) {
    self.onReading = onReading
  }

  /// Delivers one reading from a background executor.
  func emit(_ reading: Int) async {
    await Task.detached { self.onReading(reading) }.value
  }
}

/// A class mechanism that hands its engine a `[weak m]` callback.
private final class SensorMechanism: Mechanism {
  let name = "Sensor"

  /// Built during `operate`, so the callback can capture the controller.
  private(set) var engine: SensorEngine?

  /// Signals every callback that reached the MainActor, promoted or not.
  private let delivered: AsyncStream<Bool>.Continuation

  init(delivered: AsyncStream<Bool>.Continuation) {
    self.delivered = delivered
  }

  func operate(_ m: MechanismController) {
    let delivered = delivered
    engine = SensorEngine { [weak m] reading in
      // The engine's executor is not the MainActor and the controller is not
      // `Sendable`, so the hop comes first and promotion happens on the other
      // side of it — the order that makes a torn-down controller observable
      // rather than a crash.
      Task { @MainActor in
        guard let m else {
          delivered.yield(false)
          return
        }
        m.recordReading(reading)
        delivered.yield(true)
      }
    }
  }
}

@MainActor
@Test func `MECH-16 a weak controller callback works live and goes inert at teardown`()
  async throws
{
  let (deliveries, deliveryContinuation) = AsyncStream.makeStream(of: Bool.self)
  var deliveryIterator = deliveries.makeAsyncIterator()

  let mechanism = SensorMechanism(delivered: deliveryContinuation)
  var cogs: Cogs? = Cogs.forTesting(mechanisms: [mechanism])
  weak var released = cogs
  let engine = try #require(mechanism.engine)

  // Live: the callback promotes its controller and the op runs.
  await engine.emit(42)
  #expect(await deliveryIterator.next() == true)
  #expect(cogs?.peek(_readingCog) == 42)

  #if DEBUG
  // The turn is attributed to the mechanism, not to a bare op name, which is
  // the whole reason delegate work goes through the controller.
  let turns = cogs?.debugHistory.entries.filter { $0.event == .turn } ?? []
  #expect(turns.map(\.name) == ["Sensor.recordReading(_:)"])
  #endif

  // Tear the runtime down. The engine survives it: it is owned by the
  // mechanism, and the callback it holds is the thing under test.
  cogs = nil
  #expect(released == nil)

  // Inert: the same engine, the same callback, and now nothing happens.
  await engine.emit(99)
  #expect(await deliveryIterator.next() == false)

  // And the callback did not resurrect the context on its way through.
  #expect(released == nil)
}
