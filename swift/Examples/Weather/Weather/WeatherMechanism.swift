import Cog
import os

/// A MainActor notification boundary used by the nice-weather reaction.
///
/// Production writes to unified logging; tests inject an array-appending
/// closure. Keeping this side effect outside Cog state lets the reaction own
/// transition detection without mirroring whether an alert was sent.
struct Notifier {
  /// The production log destination shared by copies of ``live``.
  private static let logger = Logger(
    subsystem: "com.skeswa.cog.weather",
    category: "weather-alerts"
  )

  /// The injected MainActor side effect.
  private let alertBody: @MainActor (String) -> Void

  /// The production notifier, which records a public weather-alert message.
  static let live = Self { message in
    logger.notice("\(message, privacy: .public)")
  }

  /// Creates a notifier from its delivery side effect.
  ///
  /// - Parameter alert: MainActor work to perform for one alert message.
  init(alert: @escaping @MainActor (String) -> Void) {
    alertBody = alert
  }

  /// Delivers one alert synchronously on the MainActor.
  func alert(_ message: String) {
    alertBody(message)
  }
}

/// Weather's one mechanism: the process-lifetime alert reaction and
/// scheduling loop, registered at bootstrap.
///
/// The default `Mechanism` name drops the suffix, so registrations compose
/// under `Weather` in debug history and task names. Forecast request tasks
/// are not owned by this mechanism: `CogBox.Async` owns each generation and
/// retains it according to graph demand. The mechanism instead owns the
/// nice-weather reaction and the clock loop that periodically asks the graph
/// to refresh the selected key; when the runtime tears its scope down, future
/// asks stop while ordinary async-cog lifetime rules decide whether existing
/// work remains.
struct WeatherMechanism: Mechanism {
  /// Destination for false-to-true nice-weather transitions.
  let notifier: Notifier
  /// Injectable clock used only by the periodic scheduling task.
  var clock: any Clock<Duration> = ContinuousClock()
  /// Keys given one transient initial demand during bootstrap.
  var initialZipCodes = ZipCode.examples
  /// The ZIP selected before anything watches, or `nil` to start unselected.
  ///
  /// Initial app state belongs here rather than in the app entry point:
  /// `operate` runs inside bootstrap, so this write settles before
  /// `bootstrapApp` returns and no watcher ever observes the unselected value
  /// on its way past. It is also how a test arranges the same starting world,
  /// through `Cogs.forTesting(mechanisms:)`.
  var initialLocation: ZipCode? = .newYork
  /// Distance between periodic refresh deadlines.
  var hourlyRefreshInterval: Duration = .seconds(3_600)

  /// Registers initial demand, the alert reaction, and the periodic loop.
  ///
  /// Initial refresh calls return immediately after Cog creates each pending
  /// generation. The soon-to-render cards turn that transient demand into UI
  /// observation; if no consumer arrives, normal async grace releases it.
  ///
  /// - Parameter m: This mechanism's whole relationship with the graph. The
  ///   app entry point retains only `Cogs`; the runtime's scope owns these
  ///   registrations.
  func operate(_ m: MechanismController) {
    // Publish the cadence the loop below will actually keep, so the cards can
    // describe it instead of repeating a literal that drifts.
    m.setRefreshInterval(hourlyRefreshInterval)

    if let initialLocation {
      m.selectCurrentLocation(initialLocation)
    }

    for zip in initialZipCodes {
      m.refreshForecast(for: zip)
    }

    m.watch(
      isNiceOutsideHereCog,
      initial: .skip,
      name: "niceAlert"
    ) { wasNice, isNice in
      if isNice && !wasNice {
        notifier.alert("It is nice outside!")
      }
    }

    let clock = clock
    let hourlyRefreshInterval = hourlyRefreshInterval
    m.task(name: "hourlyRefresh") { [weak m] in
      try await runHourlyRefresh(
        on: clock,
        every: hourlyRefreshInterval,
        m: { m }
      )
    }
  }
}

/// Sleeps on deadline-based cadence and refreshes the currently selected key.
///
/// Refresh is synchronous graph demand, so service failures become status
/// and never throw out of this loop. The weak controller lookup lets scope
/// teardown release the controller even while this cancelled loop has not
/// cooperatively returned; clock cancellation and failed promotion are the
/// loop's only terminal paths.
private func runHourlyRefresh<C: Clock>(
  on clock: C,
  every interval: Duration,
  m: @escaping @MainActor () -> MechanismController?
) async throws where C.Duration == Duration {
  // The deadline advances from the previous deadline rather than from "now",
  // so a slow refresh does not make the schedule drift. A refresh that outlasts
  // the interval leaves the next deadline already past, and that tick fires
  // immediately instead of being skipped.
  var nextRefresh = clock.now.advanced(by: interval)
  while true {
    try await clock.sleep(until: nextRefresh, tolerance: nil)
    nextRefresh = nextRefresh.advanced(by: interval)
    guard let m = await m() else { return }
    guard let currentZipCode = await m.peek(currentZipCodeCog) else { continue }

    // Refresh starts graph-owned work and returns immediately. A request
    // failure becomes the forecast's `.failure` status, so it cannot terminate
    // this scheduling loop and silently disable later ticks.
    await m.refresh(weatherForecastCogs[currentZipCode])
  }
}
