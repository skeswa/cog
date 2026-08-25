#if canImport(UIKit)

import Cog
import CogTesting
import SwiftUI
import Testing
import UIKit

@available(iOS 26.0, *)
@MainActor
private struct ValuesTaskProbe: View {
  @Environment(\.cogs) private var cogs
  let valueCog: Cog<Int>
  let received: MainActorCleanupAcknowledgement

  var body: some View {
    Color.clear.task {
      for await value in cogs.values(of: valueCog) {
        #expect(value == 2)
        received.acknowledge()
      }
    }
  }
}

@available(iOS 26.0, *)
@MainActor
@Test(.timeLimit(.minutes(1)))
func `EXPORT-07 a disappearing view ends its values task and lease`() async throws {
  let clock = TestClock()
  let sourceCog = Cog<Int>.Manual { 1 }
  let doubledCog = Cog<Int> { c in
    c[sourceCog] * 2
  }
  let cogs = Cogs.forTesting(
    clock: clock,
    whileObservedGrace: .seconds(10)
  )
  let received = MainActorCleanupAcknowledgement()
  var host: UIHostingController<AnyView>? = UIHostingController(
    rootView: AnyView(
      ValuesTaskProbe(
        valueCog: doubledCog,
        received: received
      )
      .cogEnvironment(cogs)
    )
  )
  let container = UIViewController()
  let window = UIWindow(frame: UIScreen.main.bounds)
  window.rootViewController = container
  window.makeKeyAndVisible()

  let mountedHost = try #require(host)
  container.addChild(mountedHost)
  mountedHost.view.frame = container.view.bounds
  container.view.addSubview(mountedHost.view)
  mountedHost.didMove(toParent: container)

  try await received.wait()

  let released = MainActorCleanupAcknowledgement()
  cogs.acknowledgeNextAutomaticRelease(with: released)
  mountedHost.willMove(toParent: nil)
  mountedHost.view.removeFromSuperview()
  mountedHost.removeFromParent()
  host = nil

  try await clock.waitForScheduledSleep()
  clock.advance(by: .seconds(10))
  try await released.wait()
  #expect(released.hasBeenAcknowledged)

  window.isHidden = true
  window.rootViewController = nil
  clock.finish()
}

#endif
