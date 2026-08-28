#if DEBUG

import Cog
import CogTesting
import Testing

// These are public-surface proofs. Seed does not expose a turn, reaction
// queue, or history recorder, so the tests observe only the state, effects,
// and debug history an application can observe.

@MainActor
@Test func `SEED-02 seed adds no entry to debug history`() {
  let cogs = Cogs.forTesting()
  let source = Cog<Int>.Manual { 1 }

  #expect(cogs.debugHistory.count == 0)

  cogs.seed(source, to: 2)

  // The value assertion keeps a no-op seed from satisfying the history proof.
  #expect(cogs.peek(source) == 2)
  #expect(cogs.debugHistory.count == 0)
  #expect(cogs.debugHistory.entries.filter { $0.event == .turn }.isEmpty)
}

@MainActor
@Test func `SEED-02 seed does not run a reaction`() {
  let source = Cog<Int>.Manual { 1 }
  var seen: [Int] = []

  let cogs = Cogs.forTesting(mechanisms: [
    MechanismProbe { m in
      m.run { c in
        seen.append(c[source])
      }
    }
  ])
  #expect(seen == [1])

  cogs.seed(source, to: 2)

  #expect(cogs.peek(source) == 2)
  #expect(seen == [1])

  // Quietness was not cancellation: the retained registration still wakes on
  // the next real turn and observes the latest value.
  cogs.turn("seed.followup") { c in c[source] = 3 }
  #expect(seen == [1, 3])
}

@MainActor
@Test func `SEED-04 seeded setup stays quiet until the sunny stub turn`() {
  enum Weather: Equatable {
    case cloudy(Int)
    case clear(Int)

    var isNice: Bool {
      switch self {
      case .cloudy:
        return false
      case .clear(let temperature):
        return (60...90).contains(temperature)
      }
    }
  }

  struct ZipCode: Hashable {
    let digits: String
  }

  let zip = ZipCode(digits: "90210")
  let currentZipSource = Cog<ZipCode?>.Manual { nil }
  let weatherReportSource = CogBox<Weather?, ZipCode>.Manual { nil }
  var weatherReads = 0
  var alerts: [String] = []

  let isNiceOutsideHere = Cog<Bool> { c in
    guard let currentZip = c[currentZipSource] else { return false }
    weatherReads += 1
    return c[weatherReportSource[currentZip]]?.isNice == true
  }

  let cogs = Cogs.forTesting(mechanisms: [
    MechanismProbe { m in
      m.run { c in
        if c[isNiceOutsideHere] {
          alerts.append("It is nice outside!")
        }
      }
    }
  ])

  // Installation stopped at the nil ZIP and never captured a weather edge.
  #expect(weatherReads == 0)
  #expect(alerts.isEmpty)

  cogs.seed(currentZipSource, to: zip)
  cogs.seed(weatherReportSource[zip], to: .cloudy(60))

  // Setup changed both sources without settling the automatic cog or running its
  // alert. Do not read the automatic cog here: the pending dirty path is the
  // behavior this story is proving.
  #expect(cogs.peek(currentZipSource) == zip)
  #expect(cogs.peek(weatherReportSource[zip]) == .cloudy(60))
  #expect(weatherReads == 0)
  #expect(alerts.isEmpty)

  cogs.turn("weather.stub") { c in
    c[weatherReportSource[zip]] = .clear(75)
  }

  #expect(weatherReads == 1)
  #expect(alerts == ["It is nice outside!"])
}

#endif
