import Cog
import CogTesting
import Testing

private struct Decl08ZipCode: Hashable {
  let digits: String
}

@MainActor
@Test func `DECL-08 each automatic box key computes from its matching keyed source`() {
  let cogs = Cogs.forTesting()
  let here = Decl08ZipCode(digits: "90210")
  let there = Decl08ZipCode(digits: "10001")
  var keysComputed: [Decl08ZipCode] = []

  let temperatures = CogBox<Int, Decl08ZipCode>.Manual { zip in
    zip == here ? 72 : 41
  }
  let summaries = CogBox<String, Decl08ZipCode> { c, zip in
    keysComputed.append(zip)
    return "\(zip.digits):\(c[temperatures[zip]])"
  }

  #expect(cogs.peek(summaries[here]) == "90210:72")
  #expect(keysComputed == [here])

  #expect(cogs.peek(summaries[Decl08ZipCode(digits: "90210")]) == "90210:72")
  #expect(keysComputed == [here])

  #expect(cogs.peek(summaries[there]) == "10001:41")
  #expect(keysComputed == [here, there])
}

@MainActor
@Test func `DECL-08 an automatic box delivers optional keys without losing nil`() {
  let cogs = Cogs.forTesting()
  let descriptions = CogBox<String, Int?> { _, key in
    key.map(String.init) ?? "none"
  }

  #expect(cogs.peek(descriptions[nil]) == "none")
  #expect(cogs.peek(descriptions[3]) == "3")
}
