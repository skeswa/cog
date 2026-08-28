import Cog
import CogTesting
import Testing

@MainActor
@Test func `SEED-11 forTestingWithController hands back a live controller operated last`()
  throws
{
  let sourceCog = Cog<Int>.Manual { 5 }
  var order: [String] = []

  // No `seeding:` here on purpose: `seed` is debug-only (SEED-05), and this
  // proof runs in every leg, release included. Seeding-before-mechanisms is
  // MECH-12's pinned behavior; this scenario's own claims are the controller
  // being live after assembly and the probe operating last.
  let (cogs, controller) = Cogs.forTestingWithController(
    mechanisms: [
      MechanismProbe(name: "Caller") { m in
        m.watch(sourceCog.readOnly, initial: .skip, name: "watch.caller") { _, value in
          order.append("caller \(value)")
        }
      }
    ]
  )

  // The controller registers after assembly returned, and its `.run` watch
  // delivers the current value — proving the controller is live.
  controller.watch(sourceCog.readOnly, initial: .run, name: "watch.controller") { _, value in
    order.append("controller \(value)")
  }
  #expect(order == ["controller 5"])

  // Reactions fire in registration order, so the caller mechanism's watch
  // firing first proves the probe operated after every caller mechanism.
  cogs.turn(sourceCog, to: 6)
  #expect(order == ["controller 5", "caller 6", "controller 6"])
}
