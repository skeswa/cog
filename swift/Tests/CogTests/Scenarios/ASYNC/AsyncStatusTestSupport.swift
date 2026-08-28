import Cog
import CogTesting

/// Runs one controlled completion and waits through Cog's generation check.
///
/// The acknowledgement fires after Cog accepts or rejects the result and any
/// accepted status publication has completed, making the following public read
/// deterministic.
@MainActor
func resolveAsyncStatus(
  in cogs: Cogs,
  _ completion: @MainActor () -> Void
) async throws {
  let checked = MainActorCleanupAcknowledgement()
  cogs.acknowledgeNextAsyncCompletionCheck(with: checked)
  completion()
  try await checked.wait()
}
