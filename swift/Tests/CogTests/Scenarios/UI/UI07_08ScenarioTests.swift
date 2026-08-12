import Cog
import CogTesting
import Testing

@MainActor
@Test func `UI-07 a binding reads current state and writes through its named turn`() {
  let cogs = Cogtext.forTesting()
  let source = ManualCog<String>("old", name: "binding.value")
  let value = source.readOnly
  let binding = cogs.binding(for: value, name: "edit binding value") { c, newValue in
    c[source] = newValue
  }

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
  let cogs = Cogtext.forTesting()
  let text = ManualCog<String>("")
  let binding = cogs.binding(for: text, name: "type character") { c, newValue in
    c[text] = newValue
  }

  binding.wrappedValue = "c"
  #expect(binding.wrappedValue == "c")

  binding.wrappedValue = "co"
  #expect(binding.wrappedValue == "co")

  binding.wrappedValue = "cog"
  #expect(binding.wrappedValue == "cog")
}
