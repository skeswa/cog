import Cog
import CogTesting
import Testing

@MainActor private let niceTemperatureCog = ManualCog<Int>(60)

/// A conventionally named mechanism: the default `name` drops the trailing
/// "Mechanism", so registrations compose under `Weather`.
@MainActor
private struct WeatherMechanism: Mechanism {
  let taskNames: AsyncStream<String?>.Continuation

  func operate(_ m: MechanismController) {
    m.watch(niceTemperatureCog, initial: .skip, name: "niceAlert") { _, _ in }
    m.task(name: "hourlyRefresh") {
      taskNames.yield(CogTaskDiagnostic.currentTaskName)
    }
  }
}

@MainActor
@Test func `MECH-05 registration names compose under the derived mechanism name`() async {
  let (taskNames, taskNameContinuation) = AsyncStream.makeStream(of: String?.self)

  let cogs = Cogs.forTesting(mechanisms: [
    WeatherMechanism(taskNames: taskNameContinuation)
  ])

  cogs.commit("warm up") { c in c[niceTemperatureCog] = 80 }

  #if DEBUG
  // The watch ran under its composed name: the type name minus "Mechanism",
  // then the registration's own name.
  let effects = cogs.debugHistory.entries.filter { $0.event == .effect }
  #expect(effects.contains { $0.name == "Weather.niceAlert" })
  #endif

  // The owned task carries the same composed name into Apple task
  // diagnostics; the runtime seam reads the actual task name from inside it.
  var iterator = taskNames.makeAsyncIterator()
  let reportedName = await iterator.next()
  #expect(reportedName == "Weather.hourlyRefresh")
}
