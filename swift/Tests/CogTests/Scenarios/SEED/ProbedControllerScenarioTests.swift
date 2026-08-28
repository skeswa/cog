import Cog
import CogTesting
import Testing

@MainActor
@Test func `SEED-11 forTestingWithController hands back a live controller operated last`()
  throws
{
  let sourceCog = Cog<Int>.Manual { 1 }
  var order: [String] = []

  let (cogs, controller) = Cogs.forTestingWithController(
    seeding: { cogs in cogs.seed(sourceCog, to: 5) },
    mechanisms: [
      MechanismProbe(name: "Caller") { m in
        m.watch(sourceCog.readOnly, initial: .skip, name: "watch.caller") { _, value in
          order.append("caller \(value)")
        }
      }
    ]
  )

  // The controller registers after assembly returned, and its `.run` watch
  // observes the seeded value — proving both that the controller is live and
  // that seeding preceded every mechanism.
  controller.watch(sourceCog.readOnly, initial: .run, name: "watch.controller") { _, value in
    order.append("controller \(value)")
  }
  #expect(order == ["controller 5"])

  // Reactions fire in registration order, so the caller mechanism's watch
  // firing first proves the probe operated after every caller mechanism.
  cogs.turn(sourceCog, to: 6)
  #expect(order == ["controller 5", "caller 6", "controller 6"])
}
