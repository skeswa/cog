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

/// Installs Weather's process-lifetime reaction and scheduling loop.
///
/// Forecast request tasks are not owned by this group: `AsyncCogBox` owns each
/// generation and retains it according to graph demand. The group instead owns
/// the nice-weather reaction and the clock loop that periodically asks the
/// graph to refresh the selected key. Cancelling the group stops future asks;
/// ordinary async-cog lifetime rules decide whether existing work remains.
struct WeatherEffects {
  /// Destination for false-to-true nice-weather transitions.
  let notifier: Notifier
  /// Injectable clock used only by the periodic scheduling task.
  var clock: any Clock<Duration> = ContinuousClock()
  /// Keys given one transient initial demand during installation.
  var initialZipCodes = ZipCode.examples
  /// Distance between periodic refresh deadlines.
  var hourlyRefreshInterval: Duration = .seconds(3_600)

  /// Installs initial demand, the alert reaction, and the periodic loop.
  ///
  /// Initial refresh calls return immediately after Cog creates each pending
  /// generation. The soon-to-render cards turn that transient demand into UI
  /// observation; if no consumer arrives, normal async grace releases it.
  ///
  /// - Parameter cogs: The app's singular graph and owner of forecast work.
  /// The app's `Cogs` owns both effects, so the entry point needs no parallel
  /// lifecycle property.
  func install(in cogs: Cogs) {
    // Publish the cadence the loop below will actually keep, so the cards can
    // describe it instead of repeating a literal that drifts.
    cogs.setRefreshInterval(hourlyRefreshInterval)

    for zip in initialZipCodes {
      cogs.refresh(weatherForecast[zip])
    }

    cogs.effects.add(
      cogs.watch(
        isNiceOutsideHere,
        initial: .skip,
        name: "weather.niceAlert"
      ) { wasNice, isNice in
        if isNice && !wasNice {
          notifier.alert("It is nice outside!")
        }
      }
    )

    let clock = clock
    let hourlyRefreshInterval = hourlyRefreshInterval
    cogs.effects.task(name: "weather.hourlyRefresh") { [weak cogs] in
      try await runHourlyRefresh(
        on: clock,
        every: hourlyRefreshInterval,
        cogs: { cogs }
      )
    }
  }
}

/// Sleeps on deadline-based cadence and refreshes the currently selected key.
///
/// Refresh is synchronous graph demand, so service failures become metadata
/// and never throw out of this loop. The weak runtime lookup also lets an
/// isolated test or preview release its `Cogs`; clock cancellation and runtime
/// release are the loop's only terminal paths.
private func runHourlyRefresh<C: Clock>(
  on clock: C,
  every interval: Duration,
  cogs: @escaping @MainActor () -> Cogs?
) async throws where C.Duration == Duration {
  // The deadline advances from the previous deadline rather than from "now",
  // so a slow refresh does not make the schedule drift. A refresh that outlasts
  // the interval leaves the next deadline already past, and that tick fires
  // immediately instead of being skipped.
  var nextRefresh = clock.now.advanced(by: interval)
  while true {
    try await clock.sleep(until: nextRefresh, tolerance: nil)
    nextRefresh = nextRefresh.advanced(by: interval)
    guard let cogs = cogs() else { return }
    guard let zip = cogs.peek(currentZipCode) else { continue }

    // Refresh starts graph-owned work and returns immediately. A request
    // failure becomes the forecast's `.failure` metadata, so it cannot terminate
    // this scheduling loop and silently disable later ticks.
    cogs.refresh(weatherForecast[zip])
  }
}
