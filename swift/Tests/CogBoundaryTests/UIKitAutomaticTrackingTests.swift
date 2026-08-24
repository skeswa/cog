#if canImport(UIKit)

import Cog
import CogTesting
import Testing
import UIKit

@available(iOS 26.0, *)
@MainActor
private final class CogTrackingView: UIView {
  let cogs: Cogs
  let count: Cog<Int>.Manual
  var renderedValues: [Int] = []

  init(cogs: Cogs, count: Cog<Int>.Manual) {
    self.cogs = cogs
    self.count = count
    super.init(frame: .zero)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("CogTrackingView is programmatic-only.")
  }

  override func updateProperties() {
    super.updateProperties()
    renderedValues.append(cogs[count])
  }
}

@available(iOS 26.0, *)
@MainActor
@Test func `UI-11 UIKit automatically retracks a Cog boundary`() {
  let cogs = Cogs.forTesting()
  let count = Cog<Int>.Manual { 0 }
  let view = CogTrackingView(cogs: cogs, count: count)

  view.setNeedsUpdateProperties()
  view.updatePropertiesIfNeeded()
  #expect(view.renderedValues == [0])

  cogs.turn { c in c[count] = 1 }
  view.updatePropertiesIfNeeded()

  #expect(view.renderedValues == [0, 1])
}

#endif
