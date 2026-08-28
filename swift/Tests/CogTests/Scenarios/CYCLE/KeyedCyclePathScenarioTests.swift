import Cog
import CogTesting
import Testing

@MainActor
@Test func `CYCLE-07 a keyed cycle trap names every key in its path`() async {
  // CYCLE-03 proves keys reach the seam diagnostic; this proves the message a
  // user actually sees on the crash carries them too, so the two renderings
  // cannot drift apart.
  let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
    await MainActor.run {
      let cogs = Cogs.forTesting()
      let holder = KeyedCycleTrapBoxHolder()
      holder.box = CogBox<Int, String>(
        { c, key in c[holder.box[key == "home" ? "work" : "home"]] },
        name: "weather"
      )
      _ = cogs.peek(holder.box["home"])
    }
  }

  let stderr = String(decoding: result?.standardErrorContent ?? [], as: UTF8.self)
  #expect(stderr.contains("Cog dependency cycle"), "stderr was: \(stderr)")
  #expect(
    stderr.contains("weather[home] -> weather[work] -> weather[home]"),
    "stderr was: \(stderr)"
  )
}

/// Lets the keyed selector reference its own box, closing the cycle under test.
@MainActor
private final class KeyedCycleTrapBoxHolder {
  var box: CogBox<Int, String>!
}
