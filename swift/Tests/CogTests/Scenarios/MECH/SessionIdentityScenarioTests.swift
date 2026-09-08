import Cog
import CogTesting
import Testing

// Where lifetime identity comes from. These proofs are about the application
// rule the primitive depends on: mint an identity when the domain operation
// creates the lifetime, and never while a selector recomputes.

/// One sign-in lifetime. Two sign-ins for the same account differ.
private struct SessionEpoch: Equatable {
  let account: String
  let epoch: Int
}

@MainActor private let _sessionCog = Cog<SessionEpoch?>.Manual { nil }
@MainActor private let _tokenCog = Cog<String>.Manual { "" }
@MainActor private var mintedEpochs = 0

extension CogOps {
  /// Signs in, minting a fresh epoch even for an account that signed in before.
  fileprivate func signIn(as account: String) {
    mintedEpochs += 1
    let epoch = mintedEpochs
    turn { c in
      c[_sessionCog] = SessionEpoch(account: account, epoch: epoch)
      c[_tokenCog] = "token-\(epoch)-0"
    }
  }

  /// Refreshes credentials inside the current session, preserving its epoch.
  fileprivate func refreshToken(_ token: String) {
    turn(_tokenCog, to: token)
  }

  /// Signs out, ending the session lifetime.
  fileprivate func signOut() {
    turn(_sessionCog, to: nil)
  }
}

@MainActor
@Test func `MECH-35 re-signing in replaces the session while a token refresh does not`() {
  mintedEpochs = 0
  var openings: [String] = []
  var credentials: [String] = []

  let cogs = Cogs.forTesting(mechanisms: [
    MechanismProbe { m in
      m.scope(_sessionCog, name: "session") { session, s in
        openings.append("\(session.account)#\(session.epoch)")
        // The credential context is captured per lifetime, before any I/O. A
        // rotation inside this session updates it; a new session gets its own.
        s.watch(_tokenCog, initial: .run, name: "credentials") { _, token in
          credentials.append("\(session.epoch):\(token)")
        }
      }
    }
  ])
  #expect(openings.isEmpty)

  cogs.signIn(as: "ada")
  #expect(openings == ["ada#1"])
  #expect(credentials == ["1:token-1-0"])

  // Token refresh preserves the epoch, so the session scope is untouched and
  // its existing registrations see the rotation.
  cogs.refreshToken("token-1-1")
  #expect(openings == ["ada#1"])
  #expect(credentials == ["1:token-1-0", "1:token-1-1"])

  // The same account signing in again is a new lifetime, not a refresh.
  cogs.signOut()
  cogs.signIn(as: "ada")
  #expect(openings == ["ada#1", "ada#2"])
  #expect(credentials.last == "2:token-2-0")

  // And a straight account switch, with no intervening signed-out turn, still
  // replaces the lifetime exactly once.
  cogs.signIn(as: "grace")
  #expect(openings == ["ada#1", "ada#2", "grace#3"])
}

@MainActor
@Test func `MECH-37 retiring one consumer leaves shared async work to its other owners`()
  async
{
  // Retirement is registration ownership. It does not cancel a generation
  // another consumer still wants, and it does not fabricate release of shared
  // state.
  let work = ControlledWork<Int>()
  let forecast = Cog<Int>.Async(default: 0, name: "forecast") { _ in work.makeWork() }
  let presentationOpen = Cog<Bool>.Manual { true }
  var presentationValues: [Int] = []
  var appValues: [Int] = []
  var handle: CogRefresh<Int>?

  let cogs = Cogs.forTesting(mechanisms: [
    MechanismProbe(name: "App") { m in
      // The durable consumer: it outlives the presentation.
      m.watch(forecast, initial: .skip, name: "app") { _, value in appValues.append(value) }
    },
    MechanismProbe(name: "Presentation") { m in
      m.scope(presentationOpen, name: "screen") { s in
        s.watch(forecast, initial: .skip, name: "screen") { _, value in
          presentationValues.append(value)
        }
        // A refresh started while live keeps its own exact-generation handle.
        handle = s.refresh(forecast)
      }
    },
  ])

  var starts = work.starts.makeAsyncIterator()
  // Generation 0 is the app watch's first cold read; generation 1 is the
  // presentation's explicit refresh, which supersedes it under `.latest`.
  #expect(await starts.next() == 0)
  #expect(await starts.next() == 1)

  // The presentation ends while its refresh is still in flight.
  cogs.turn(presentationOpen, to: false)

  // The generation completes. The shared state is still owned by the app-level
  // watch, so the value publishes normally.
  work.succeed(1, with: 72)
  let outcome = await handle!.outcome
  guard case .success(let value) = outcome else {
    Issue.record("expected a real success outcome, got \(outcome)")
    return
  }
  #expect(value == 72)
  #expect(appValues == [72])

  // The retired presentation's watch received nothing, and nothing pretended
  // the shared state was released.
  #expect(presentationValues.isEmpty)
  #expect(cogs.peek(forecast) == 72)
}
