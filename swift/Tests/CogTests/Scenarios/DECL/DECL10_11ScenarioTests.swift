import Cog
import CogTesting
import Testing

// DECL-10 and DECL-11 are about what Cog *calls* a declaration. Cog talks
// about declarations in exactly two places — a cycle diagnostic and debug
// history — so each scenario proves the same label reaches both. A test that
// checked only one surface would let the other drift.

@MainActor
@Test func `DECL-10 a named cog carries its name into a cycle diagnostic`() {
  let cogs = Cogs.forTesting()
  var diagnostic: CogCycleDiagnostic?
  var advice: Cog<Int>!

  advice = Cog<Int>(
    { c in
      if let cycle = c.cycleDiagnostic(ifReading: advice) {
        diagnostic = cycle
        return 0
      }
      return c[advice]
    },
    name: "advice"
  )

  #expect(cogs.peek(advice) == 0)
  #expect(diagnostic?.path == ["advice", "advice"])
  #expect(diagnostic?.message == "Cog dependency cycle: advice -> advice.")
}

@MainActor
@Test func `DECL-11 an unnamed cog falls back to its declaration site in a cycle diagnostic`() {
  let cogs = Cogs.forTesting()
  var diagnostic: CogCycleDiagnostic?
  var ratio: Cog<Int>!

  let beforeDeclaration = UInt(#line)
  ratio = Cog<Int> { c in
    if let cycle = c.cycleDiagnostic(ifReading: ratio) {
      diagnostic = cycle
      return 0
    }
    return c[ratio]
  }
  let afterDeclaration = UInt(#line)

  #expect(cogs.peek(ratio) == 0)

  // The fallback is one label repeated, so both steps say the same thing.
  #expect(diagnostic?.path.count == 2)
  #expect(diagnostic?.path.first == diagnostic?.path.last)

  let site = declarationSite(diagnostic?.path.first)
  #expect(site?.file.hasSuffix("DECL10_11ScenarioTests.swift") == true)
  // A range, not an equality: which line of a multi-line call expression
  // `#line` reports is the compiler's business. DECL-11 asks only that the
  // fallback points at this declaration rather than at some other one.
  #expect(site.map { $0.line > beforeDeclaration && $0.line < afterDeclaration } == true)
}

#if DEBUG

@MainActor
@Test func `DECL-10 a named cog carries its name into debug history`() {
  let cogs = Cogs.forTesting()
  let temperature = ManualCog<Int>(60, name: "temperature")
  let advice = Cog<String>(
    { c in c[temperature] > 70 ? "shorts" : "coat" },
    name: "advice"
  )

  #expect(cogs.peek(advice) == "coat")

  cogs.commit("warm up") { c in c[temperature] = 80 }
  #expect(cogs.peek(advice) == "shorts")

  let entries = cogs.debugHistory.entries
  #expect(entries.filter { $0.event == .write }.map(\.name) == ["temperature"])
  #expect(entries.filter { $0.event == .recompute }.map(\.name) == ["advice", "advice"])
}

@MainActor
@Test func `DECL-11 an unnamed cog falls back to its declaration site in debug history`() {
  let cogs = Cogs.forTesting()

  let beforeSource = UInt(#line)
  let temperature = ManualCog<Int>(60)
  let afterSource = UInt(#line)

  let beforeDerived = UInt(#line)
  let advice = Cog<String> { c in c[temperature] > 70 ? "shorts" : "coat" }
  let afterDerived = UInt(#line)

  #expect(cogs.peek(advice) == "coat")
  cogs.commit("warm up") { c in c[temperature] = 80 }
  #expect(cogs.peek(advice) == "shorts")

  let entries = cogs.debugHistory.entries

  // Two unnamed declarations in one file still name themselves apart, because
  // the fallback is a line and not just a file.
  let writes = entries.filter { $0.event == .write }.map(\.name)
  #expect(writes.count == 1)
  let writeSite = declarationSite(writes.first)
  #expect(writeSite?.file.hasSuffix("DECL10_11ScenarioTests.swift") == true)
  #expect(writeSite.map { $0.line > beforeSource && $0.line < afterSource } == true)

  let recomputes = Set(entries.filter { $0.event == .recompute }.map(\.name))
  #expect(recomputes.count == 1)
  let recomputeSite = declarationSite(recomputes.first)
  #expect(recomputeSite?.file.hasSuffix("DECL10_11ScenarioTests.swift") == true)
  #expect(recomputeSite.map { $0.line > beforeDerived && $0.line < afterDerived } == true)
}

#endif

/// Splits a rendered fallback label into the file and line it points at.
///
/// Returns `nil` when `label` is absent or is not spelled `fileID:line`, which
/// makes "Cog printed a name where it promised a declaration site" fail rather
/// than silently pass an assertion about a `nil` value.
@MainActor
private func declarationSite(_ label: String?) -> (file: String, line: UInt)? {
  guard let label,
    let separator = label.lastIndex(of: ":"),
    let line = UInt(label[label.index(after: separator)...])
  else { return nil }
  return (String(label[..<separator]), line)
}
