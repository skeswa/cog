import Cog
import SwiftUI

/// The hike logger, presented as the app's one modal layer.
///
/// The elapsed clock it shows is graph state ticked by a `whenever` scope
/// gated on this sheet's presence, so opening the sheet — by button, deep
/// link, or restoration — starts the clock, and any dismissal stops it. The
/// note draft, by contrast, is truly view-local until committed, so it stays
/// in `@State`.
struct HikeLoggerSheet: View {
  /// Runtime resolved directly by this sheet boundary.
  @Environment(\.cogs) private var cogs
  /// The trail the hike is logged against.
  let trailID: TrailID
  /// Uncommitted note text; it becomes graph state only on save.
  @State private var note = ""

  /// Renders the timer, note field, and commit actions.
  var body: some View {
    let hikeTimerSeconds = cogs[hikeTimerSecondsCog]

    NavigationStack {
      Form {
        Section {
          LabeledContent("Elapsed") {
            Text(formattedDuration(of: hikeTimerSeconds))
              .font(.body.monospacedDigit())
              .contentTransition(.numericText())
          }
        } footer: {
          Text("A whenever scope gated on this sheet's presence drives the clock.")
        }

        Section("Note") {
          TextField("How was the trail?", text: $note, axis: .vertical)
            .lineLimit(3...6)
        }
      }
      .navigationTitle(TrailCatalog.trail(trailID)?.name ?? "Log a hike")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            cogs.dismissSheet()
          }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") {
            cogs.logHike(for: trailID, note: note)
          }
        }
      }
    }
  }

  /// Formats whole seconds as a minutes-and-seconds clock.
  ///
  /// - Parameter seconds: Elapsed whole seconds from the gated timer.
  private func formattedDuration(of seconds: Int) -> String {
    let minutes = seconds / 60
    let remainder = seconds % 60
    return String(format: "%d:%02d", minutes, remainder)
  }
}
