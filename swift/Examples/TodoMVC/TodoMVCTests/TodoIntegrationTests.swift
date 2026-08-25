#if DEBUG

import Cog
import CogTesting
import Observation
import Testing

/// One-shot Observation probe matching the flat reads in ``TodoRow``.
@MainActor
private final class TrackedTodoRow {
  /// Graph under observation.
  let cogs: Cogs
  /// Key whose row fields are tracked.
  let id: TodoID
  /// Number of one-shot invalidations received.
  private(set) var invalidations = 0
  /// Row values captured at each explicit render.
  private(set) var snapshots: [(String, Bool)] = []
  /// Whether a later explicit frame must re-arm tracking.
  private var needsRender = false

  /// Creates a dormant row probe.
  init(cogs: Cogs, id: TodoID) {
    self.cogs = cogs
    self.id = id
  }

  /// Performs the first tracked render.
  func start() {
    render()
  }

  /// Performs the next frame only after an invalidation.
  func renderFrame() {
    guard needsRender else { return }
    needsRender = false
    render()
  }

  /// Reads exactly the two keyed values the real row reads.
  private func render() {
    withObservationTracking {
      let todoTitle = cogs[todoTitleCogs[id]]
      let todoIsCompleted = cogs[todoIsCompletedCogs[id]]
      snapshots.append((todoTitle, todoIsCompleted))
    } onChange: { [weak self] in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.invalidations += 1
        self.needsRender = true
      }
    }
  }

  /// Explicitly avoids an unnecessary MainActor deallocation hop.
  nonisolated deinit {}
}

/// One-shot Observation probe matching the dashboard's visible-ID read.
@MainActor
private final class TrackedVisibleList {
  /// Graph under observation.
  let cogs: Cogs
  /// Number of equality-gated visible-list invalidations.
  private(set) var invalidations = 0
  /// Visible membership captured at each explicit render.
  private(set) var snapshots: [[TodoID]] = []
  /// Whether a later explicit frame must re-arm tracking.
  private var needsRender = false

  /// Creates a dormant list probe.
  init(cogs: Cogs) {
    self.cogs = cogs
  }

  /// Performs the first tracked render.
  func start() {
    render()
  }

  /// Performs the next frame only after an invalidation.
  func renderFrame() {
    guard needsRender else { return }
    needsRender = false
    render()
  }

  /// Reads the same automatic membership value as the dashboard.
  private func render() {
    withObservationTracking {
      let visibleTodoIDs = cogs[visibleTodoIDsCog]
      snapshots.append(visibleTodoIDs)
    } onChange: { [weak self] in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.invalidations += 1
        self.needsRender = true
      }
    }
  }

  /// Explicitly avoids an unnecessary MainActor deallocation hop.
  nonisolated deinit {}
}

@MainActor
@Test func keyedRowChangesInvalidateOnlyTheRowThatReadsThem() {
  let first = TodoItem(id: todoID(1), title: "First", isCompleted: false)
  let second = TodoItem(id: todoID(2), title: "Second", isCompleted: false)
  let cogs = Cogs.forTesting(seeding: { $0.seedTodos([first, second]) })
  let firstRow = TrackedTodoRow(cogs: cogs, id: first.id)
  let secondRow = TrackedTodoRow(cogs: cogs, id: second.id)
  firstRow.start()
  secondRow.start()

  cogs.toggleTodo(first.id)
  #expect(firstRow.invalidations == 1)
  #expect(secondRow.invalidations == 0)
  firstRow.renderFrame()

  cogs.editTodoTitle("Second, edited", for: second.id)
  #expect(firstRow.invalidations == 1)
  #expect(secondRow.invalidations == 1)
  secondRow.renderFrame()

  #expect(firstRow.snapshots.count == 2)
  #expect(firstRow.snapshots.last?.0 == "First")
  #expect(firstRow.snapshots.last?.1 == true)
  #expect(secondRow.snapshots.count == 2)
  #expect(secondRow.snapshots.last?.0 == "Second, edited")
  #expect(secondRow.snapshots.last?.1 == false)
}

@MainActor
@Test func allFilterAvoidsCompletionEdgesUntilMembershipNeedsThem() {
  let first = TodoItem(id: todoID(1), title: "First", isCompleted: false)
  let second = TodoItem(id: todoID(2), title: "Second", isCompleted: false)
  let cogs = Cogs.forTesting(seeding: { $0.seedTodos([first, second]) })
  let list = TrackedVisibleList(cogs: cogs)
  list.start()

  cogs.toggleTodo(first.id)
  #expect(list.invalidations == 0)

  cogs.selectTodoFilter(.active)
  #expect(list.invalidations == 1)
  list.renderFrame()
  #expect(list.snapshots.last == [second.id])

  cogs.toggleTodo(second.id)
  #expect(list.invalidations == 2)
  list.renderFrame()
  #expect(list.snapshots.last == [])
}

#endif
