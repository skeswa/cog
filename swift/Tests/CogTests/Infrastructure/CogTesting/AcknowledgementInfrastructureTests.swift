import CogTesting
import Testing

@MainActor
@Test func `CogTestingAcknowledgementInfrastructure waits for MainActor cleanup`() async throws {
  let cleanupFinished = MainActorCleanupAcknowledgement()
  var didAcknowledge = false

  let signaler = Task { @MainActor in
    MainActor.preconditionIsolated()
    didAcknowledge = true
    cleanupFinished.acknowledge()
  }

  try await cleanupFinished.wait()
  #expect(didAcknowledge)
  await signaler.value
}

@MainActor
@Test
func `CogTestingAcknowledgementInfrastructure buffers cleanup before the wait`() async throws {
  let cleanupFinished = MainActorCleanupAcknowledgement()
  cleanupFinished.acknowledge()

  try await cleanupFinished.wait()
}
