#if canImport(AppKit)

import AppKit
import Cog
import CogTesting
import Testing

@available(macOS 26.0, *)
@MainActor
private final class CogTrackingNSView: NSView {
  let cogs: Cogs
  let count: ManualCog<Int>
  var renderedValues: [Int] = []

  init(cogs: Cogs, count: ManualCog<Int>) {
    self.cogs = cogs
    self.count = count
    super.init(frame: .zero)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("CogTrackingNSView is programmatic-only.")
  }

  override func layout() {
    super.layout()
    renderedValues.append(cogs[count])
  }
}

@available(macOS 26.0, *)
@MainActor
@Test func `UI-12 AppKit automatically retracks a Cog boundary`() {
  let cogs = Cogs.forTesting()
  let count = ManualCog<Int>(0)
  let view = CogTrackingNSView(cogs: cogs, count: count)

  view.needsLayout = true
  view.layoutSubtreeIfNeeded()
  #expect(view.renderedValues == [0])

  cogs.turn { c in c[count] = 1 }
  view.layoutSubtreeIfNeeded()

  #expect(view.renderedValues == [0, 1])
}

#endif
