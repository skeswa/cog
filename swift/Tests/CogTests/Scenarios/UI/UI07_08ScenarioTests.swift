import Cog
import CogTesting
import SwiftUI
import Testing

@MainActor
@Test func `UI-07 a binding reads current state and writes through its named turn`() {
  let cogs = Cogs.forTesting()
  let source = ManualCog<String>("old", name: "binding.value")
  let value = source.readOnly
  let binding = Binding(
    get: { cogs[value] },
    set: { cogs.commit(source, to: $0, name: "edit binding value") }
  )

  #expect(binding.wrappedValue == "old")

  binding.wrappedValue = "new"

  #expect(cogs.peek(value) == "new")

  #if DEBUG
  let entries = cogs.debugHistory.entries
  #expect(entries.contains { $0.event == .turn && $0.name == "edit binding value" })
  #expect(entries.contains { $0.event == .write && $0.name == "binding.value" })
  #endif
}

@MainActor
@Test func `UI-08 a binding reads its write back immediately`() {
  let cogs = Cogs.forTesting()
  let text = ManualCog<String>("")
  let binding = Binding(
    get: { cogs[text] },
    set: { cogs.commit(text, to: $0, name: "type character") }
  )

  binding.wrappedValue = "c"
  #expect(binding.wrappedValue == "c")

  binding.wrappedValue = "co"
  #expect(binding.wrappedValue == "co")

  binding.wrappedValue = "cog"
  #expect(binding.wrappedValue == "cog")
}
