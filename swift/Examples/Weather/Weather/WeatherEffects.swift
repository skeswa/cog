import Cog
import os

@MainActor
struct Notifier {
  private static let logger = Logger(
    subsystem: "com.skeswa.cog.weather",
    category: "weather-alerts"
  )

  private let alertBody: @MainActor (String) -> Void

  static let live = Self { message in
    logger.notice("\(message, privacy: .public)")
  }

  init(alert: @escaping @MainActor (String) -> Void) {
    alertBody = alert
  }

  func alert(_ message: String) {
    alertBody(message)
  }
}

@MainActor
struct WeatherEffects {
  let notifier: Notifier
  var clock: any Clock<Duration> = ContinuousClock()
  var initialZipCodes = ZipCode.examples
  var hourlyRefreshInterval: Duration = .seconds(3_600)

  @discardableResult
  func install(in cogs: Cogtext) -> EffectGroup {
    let group = EffectGroup()

    for zip in initialZipCodes {
      group.task(name: "weather.initialRefresh[\(zip)]") {
        try await cogs.checkWeather(zip)
      }
    }

    group.add(
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
    group.task(name: "weather.hourlyRefresh") {
      try await runHourlyRefresh(
        on: clock,
        every: hourlyRefreshInterval,
        in: cogs
      )
    }

    return group
  }
}

private func runHourlyRefresh<C: Clock>(
  on clock: C,
  every interval: Duration,
  in cogs: Cogtext
) async throws where C.Duration == Duration {
  var nextRefresh = clock.now.advanced(by: interval)
  while true {
    try await clock.sleep(until: nextRefresh, tolerance: nil)
    nextRefresh = nextRefresh.advanced(by: interval)
    guard let zip = cogs.read(currentZipCode) else { continue }
    try await cogs.checkWeather(zip)
  }
}
