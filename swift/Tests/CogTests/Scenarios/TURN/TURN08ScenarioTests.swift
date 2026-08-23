import Cog
import CogTesting
import Testing

@MainActor
@Test func `TURN-08 queued turns finish one full flush at a time in FIFO order`() {
  let (cogs, m) = probedContext()
  let trigger = Cog<Int>.Manual(0)
  let value = Cog<Int>.Manual(0)
  var events: [String] = []

  let doubled = Cog<Int> { c in
    let result = c[value] * 2
    events.append("settle:\(result)")
    return result
  }

  m.run { c in
    guard c[trigger] == 1 else { return }

    for next in 1...3 {
      cogs.turn("queued.\(next)") { c in
        events.append("body:\(next)")
        c[value] = next
      }
    }
  }

  m.run { c in
    events.append("react:\(c[doubled])")
  }

  events.removeAll()
  cogs.turn { c in c[trigger] = 1 }

  // No UI boundary is registered in this host test, so the notify phase is
  // empty. Seeing each reaction complete before the next body begins proves
  // the entire settle-notify-react flush barrier still completed in between.
  #expect(
    events == [
      "body:1",
      "settle:2",
      "react:2",
      "body:2",
      "settle:4",
      "react:4",
      "body:3",
      "settle:6",
      "react:6",
    ]
  )
}
