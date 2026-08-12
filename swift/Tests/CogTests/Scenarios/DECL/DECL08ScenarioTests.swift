import Cog
import CogTesting
import Testing

private struct Decl08ZipCode: Hashable {
  let digits: String
}

@MainActor
@Test func `DECL-08 each derived box key computes from its matching keyed source`() {
  let cogs = Cogtext.forTesting()
  let here = Decl08ZipCode(digits: "90210")
  let there = Decl08ZipCode(digits: "10001")
  var keysComputed: [Decl08ZipCode] = []

  let temperatures = ManualCogBox<Int, Decl08ZipCode> { zip in
    zip == here ? 72 : 41
  }
  let summaries = CogBox<String, Decl08ZipCode> { c, zip in
    keysComputed.append(zip)
    return "\(zip.digits):\(c.get(temperatures[zip]))"
  }

  #expect(cogs.read(summaries[here]) == "90210:72")
  #expect(keysComputed == [here])

  #expect(cogs.read(summaries[Decl08ZipCode(digits: "90210")]) == "90210:72")
  #expect(keysComputed == [here])

  #expect(cogs.read(summaries[there]) == "10001:41")
  #expect(keysComputed == [here, there])
}

@MainActor
@Test func `DECL-08 a derived box delivers optional keys without losing nil`() {
  let cogs = Cogtext.forTesting()
  let descriptions = CogBox<String, Int?> { _, key in
    key.map(String.init) ?? "none"
  }

  #expect(cogs.read(descriptions[nil]) == "none")
  #expect(cogs.read(descriptions[3]) == "3")
}
