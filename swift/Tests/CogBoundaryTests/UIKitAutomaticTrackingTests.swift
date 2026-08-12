#if canImport(UIKit)

import Cog
import CogTesting
import Testing
import UIKit

@available(iOS 26.0, *)
@MainActor
private final class CogTrackingView: UIView {
  let cogs: Cogtext
  let count: ManualCog<Int>
  var renderedValues: [Int] = []

  init(cogs: Cogtext, count: ManualCog<Int>) {
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
    renderedValues.append(cogs.get(count))
  }
}

@available(iOS 26.0, *)
@MainActor
@Test func `UI-11 UIKit automatically retracks a Cog boundary`() {
  let cogs = Cogtext.forTesting()
  let count = ManualCog<Int>(0)
  let view = CogTrackingView(cogs: cogs, count: count)

  view.setNeedsUpdateProperties()
  view.updatePropertiesIfNeeded()
  #expect(view.renderedValues == [0])

  cogs.commit { writer in writer[count] = 1 }
  view.updatePropertiesIfNeeded()

  #expect(view.renderedValues == [0, 1])
}

#endif
