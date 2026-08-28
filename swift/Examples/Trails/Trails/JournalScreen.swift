import Cog
import SwiftUI

/// The Journal tab's root: the session's screen-visit log, made tappable.
///
/// Every row shows the URL that reproduces its screen, and tapping a row
/// feeds that link back through the same `open` operation that Safari or a
/// widget would use. A journal mechanism reacts to the derived current screen
/// and writes the list, so screens need no tracking code.
struct JournalScreen: View {
  /// Runtime resolved directly by this screen boundary.
  @Environment(\.cogs) private var cogs

  /// Renders the visit log, newest first, with a clear action.
  var body: some View {
    let screenJournal = cogs[screenJournalCog]

    List {
      Section {
        ForEach(screenJournal) { visit in
          Button {
            cogs.open(visit.screen.deepLink)
          } label: {
            JournalRow(visit: visit)
          }
          .buttonStyle(.plain)
        }
      } footer: {
        if !screenJournal.isEmpty {
          Text(
            "One mechanism reaction on the derived current-screen value wrote "
              + "every entry here. Tap a row to revisit it through its URL."
          )
        }
      }
    }
    .overlay {
      if screenJournal.isEmpty {
        ContentUnavailableView(
          "No visits yet",
          systemImage: "clock.arrow.circlepath",
          description: Text("Navigate anywhere and each screen will be recorded here.")
        )
      }
    }
    .navigationTitle("Journal")
    .toolbar {
      if !screenJournal.isEmpty {
        Button("Clear") {
          cogs.clearScreenJournal()
        }
        .accessibilityLabel("Clear the journal")
      }
    }
  }
}

/// One visit row: the screen's name over its reproducing URL.
private struct JournalRow: View {
  /// The recorded visit backing this row.
  let visit: TrailScreenVisit

  /// Renders the visit's label, symbol, and canonical link.
  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: visit.screen.journalSymbol)
        .font(.headline)
        .foregroundStyle(TrailsTheme.accent)
        .frame(width: 30)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 2) {
        Text(visit.screen.journalLabel)
          .font(.body.weight(.medium))

        Text(visit.screen.deepLink.url.absoluteString)
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    }
    .padding(.vertical, 2)
    .contentShape(Rectangle())
  }
}
