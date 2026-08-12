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
    group.task(name: "weather.hourlyRefresh") {
      while true {
        try await clock.sleep(for: .seconds(3_600))
        guard let zip = await cogs.read(currentZipCode) else { continue }
        try await cogs.checkWeather(zip)
      }
    }

    return group
  }
}
