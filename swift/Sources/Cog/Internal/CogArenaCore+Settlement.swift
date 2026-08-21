#if COG_CORE_ARENA

// MARK: - Settlement

/// Iterative pull settlement, dependency reconciliation, and cycle detection.
///
/// Reused scalar buffers carry the warm path. Typed selector dispatch happens
/// only after dependencies are current, and publication completes before the
/// active row leaves the computing path.
extension CogArenaCore {
  /// Pulls one derived row current through reusable scalar enter/exit frames.
  func settle(_ root: CogArenaSlot, in cogs: Cogs) {
    defer { cogs.drainQueuedTurnsIfPossible() }
    cogs.settleDepth += 1
    defer { cogs.settleDepth -= 1 }
    if cogs.settleDepth > Cogs.maximumSettleDepth {
      fatalError(
        cogs.coldSettleDepthMessage(
          innermostComputingNames: innermostComputingNames(8)
        )
      )
    }

    let rootRow = arena.index(of: root)
    let boundary = pullFrames.count
    pullFrames.append(CogArenaPullFrame(row: Int32(rootRow), phase: .enter))

    while pullFrames.count > boundary, let frame = pullFrames.popLast() {
      let row = liveRow(frame.row)
      switch frame.phase {
      case .enter:
        guard needsSettlement(row) else { continue }
        let record = descriptorRecord(forRow: row)
        guard record.kind != .manual else {
          fatalError("Cog found an invalid manual source in the arena pull walk.")
        }

        if let cycle = cyclePath(ifEnteringRow: row) {
          fatalError(cycle.message)
        }

        beginComputing(row)
        pullFrames.append(CogArenaPullFrame(row: frame.row, phase: .exit))
        appendDependencies(of: frame.row)

      case .exit:
        defer { endComputing(row) }
        let record = descriptorRecord(forRow: row)
        let mustRecompute = arena.flags[row].contains(.dirty) || dependencyChanged(for: frame.row)
        if mustRecompute {
          guard let recompute = record.recompute else {
            fatalError("Cog found a derived arena row without a recompute function.")
          }
          let slot = CogArenaSlot(index: frame.row, generation: arena.generation[row])
          recompute(self, cogs, slot, record.key(at: row))
        } else {
          arena.checkedAt[row] = revision
          arena.flags[row].remove(.check)
          arena.flags[row].remove(.dirty)
        }
      }
    }
  }

  /// Appends stale producers of `consumerRow` for settlement before its exit.
  func appendDependencies(of consumerRow: Int32) {
    var cursor = edges.firstDependency(of: consumerRow, in: arena)
    while cursor != .none {
      let dependency = edges.dependency(at: cursor)
      guard dependency.consumer == consumerRow else {
        fatalError("Cog found another consumer's edge in an arena dependency list.")
      }
      let producerRow = liveRow(dependency.producer)
      if needsSettlement(producerRow) {
        pullFrames.append(CogArenaPullFrame(row: dependency.producer, phase: .enter))
      }
      cursor = dependency.next
    }
  }

  /// Whether any dependency changed after this consumer was last current.
  func dependencyChanged(for consumerRow: Int32) -> Bool {
    let checkedAt = arena.checkedAt[Int(consumerRow)]
    var cursor = edges.firstDependency(of: consumerRow, in: arena)
    while cursor != .none {
      let dependency = edges.dependency(at: cursor)
      guard dependency.consumer == consumerRow else {
        fatalError("Cog found another consumer's edge in an arena dependency list.")
      }
      if arena.changedAt[liveRow(dependency.producer)] > checkedAt {
        return true
      }
      cursor = dependency.next
    }
    return false
  }

  /// Runs one typed selector and publishes or backdates its completed result.
  func recompute<Value>(
    descriptor: DerivedCogDescriptor<Value>,
    column: CogArenaValueColumn<Value>,
    slot: CogArenaSlot,
    key: CogKey?,
    in cogs: Cogs
  ) {
    #if DEBUG
    // Dependency capture ends before equality and publication below. Keep seed
    // blocked across that complete interval so a selector or comparator cannot
    // mutate a source and then have this run clean over the resulting dirty mark.
    cogs.seedBarrierDepth += 1
    defer { cogs.seedBarrierDepth -= 1 }
    recordHistoryState(event: .recompute, slot: slot)
    #endif
    let previousValue = column.storedValue(at: slot)
    let value = withDependencyCapture(for: slot) {
      descriptor.compute(Reader(cogs: cogs, arenaState: slot), key: key)
    }

    let changed: Bool
    if case .some = previousValue {
      column.stage(value, at: slot)
      changed = column.commit(at: slot)
    } else {
      column.insert(value, at: slot)
      changed = true
    }

    let row = arena.index(of: slot)
    if changed {
      arena.changedAt[row] = revision
    }
    arena.checkedAt[row] = revision
    arena.flags[row].remove(.check)
    arena.flags[row].remove(.dirty)
  }

  /// Runs one async selector, reconciles indexed dependencies, and starts work.
  func recomputeAsync<Value>(
    descriptor: AsyncCogDescriptor<Value>,
    column: CogArenaAsyncColumn<Value>,
    slot: CogArenaSlot,
    key: CogKey?,
    publishingPendingIn pendingTurn: CogTurn? = nil,
    refreshWaiter: CogRefreshWaiter<Value>? = nil,
    in cogs: Cogs
  ) {
    #if DEBUG
    cogs.seedBarrierDepth += 1
    defer { cogs.seedBarrierDepth -= 1 }
    #endif
    let work = withDependencyCapture(for: slot) {
      descriptor.makeWork(Reader(cogs: cogs, arenaState: slot), key: key)
    }
    column.startWork(
      work,
      at: slot,
      key: key,
      publishingPendingIn: pendingTurn,
      refreshWaiter: refreshWaiter,
      in: self,
      cogs: cogs
    )

    let row = arena.index(of: slot)
    arena.checkedAt[row] = revision
    arena.flags[row].remove(.check)
    arena.flags[row].remove(.dirty)
  }

  /// Runs one selector with a nested static-prefix dependency cursor.
  func withDependencyCapture<Result>(
    for consumer: CogArenaSlot,
    _ body: () -> Result
  ) -> Result {
    let row = arena.index(of: consumer)
    captures.append(
      CogArenaDependencyCapture(
        consumer: consumer,
        cursor: edges.firstDependency(of: Int32(row), in: arena),
        previous: .none
      )
    )
    defer {
      guard let finished = captures.popLast(), finished.consumer == consumer else {
        fatalError("Cog finished arena dependency capture out of order.")
      }
      if finished.cursor != .none {
        edges.removeDependencySuffix(
          of: consumer,
          after: finished.previous,
          in: arena
        )
      }
    }
    return body()
  }

  /// Reuses the next matching edge or appends one cold static dependency.
  func recordDependency(from consumer: CogArenaSlot, on producer: CogArenaSlot) {
    guard let captureIndex = captures.indices.last else {
      fatalError("Cog recorded an arena dependency outside selector capture.")
    }
    var capture = captures[captureIndex]
    guard capture.consumer == consumer else {
      fatalError("Cog recorded an arena dependency for a non-active selector.")
    }

    if capture.cursor != .none {
      let dependency = edges.dependency(at: capture.cursor)
      if dependency.producer == producer.index, dependency.consumer == consumer.index {
        edges.updateVersion(
          of: capture.cursor,
          to: arena.changedAt[arena.index(of: producer)]
        )
        capture.previous = capture.cursor
        capture.cursor = dependency.next
        captures[captureIndex] = capture
        return
      }

      edges.removeDependencySuffix(
        of: consumer,
        after: capture.previous,
        in: arena
      )
      capture.cursor = .none
    }

    let added = edges.add(
      producer: producer,
      consumer: consumer,
      after: capture.previous,
      version: arena.changedAt[arena.index(of: producer)],
      in: arena
    )
    capture.previous = added

    captures[captureIndex] = capture
  }

  /// Whether one row carries CHECK or DIRTY work.
  func needsSettlement(_ row: Int) -> Bool {
    arena.flags[row].contains(.check) || arena.flags[row].contains(.dirty)
  }

  /// Returns the closed active-path suffix when `row` is already computing.
  ///
  /// The packed row bit is the common fast path. Only a detected cycle scans
  /// and renders the ordered path, so ordinary settlement does no identity or
  /// key work beyond the scalar flag check.
  func cyclePath(ifEnteringRow row: Int) -> CogCyclePath? {
    guard arena.flags[row].contains(.computing) else { return nil }
    let rawRow = Int32(row)
    guard let first = computingPath.firstIndex(of: rawRow) else {
      fatalError("An arena row was marked computing without an active path entry.")
    }
    let steps =
      computingPath[first...].map { cycleStep(forRow: liveRow($0)) }
      + [cycleStep(forRow: row)]
    return CogCyclePath(steps: steps)
  }

  /// Marks and appends one row after cycle detection has succeeded.
  func beginComputing(_ row: Int) {
    guard cyclePath(ifEnteringRow: row) == nil else {
      fatalError("Cog tried to enter an arena derived cycle without reporting it.")
    }
    arena.flags[row].insert(.computing)
    computingPath.append(Int32(row))
  }

  /// Clears the innermost row while enforcing balanced nested settlement.
  func endComputing(_ row: Int) {
    guard computingPath.last == Int32(row) else {
      fatalError("Cog tried to finish arena derived computation out of path order.")
    }
    computingPath.removeLast()
    arena.flags[row].remove(.computing)
  }

  /// Erases one row into the renderer shared by both runtime cores.
  func cycleStep(forRow row: Int) -> CogCycleStep {
    let record = descriptorRecord(forRow: row)
    return CogCycleStep(
      descriptor: record.identity,
      label: record.label,
      key: record.key(at: row)
    )
  }

  /// Diagnoses a hypothetical derived read without creating a row or edge.
  ///
  /// The lookup is intentionally observational. A missing descriptor-and-key
  /// identity returns `nil`, preserving lazy row creation and later edge order.
  func cycleDiagnosticSnapshot<Value>(
    ifReading valueReference: Cog<Value>
  ) -> CogCycleDiagnosticSnapshot? {
    let identity = CogStateIdentity(
      descriptor: valueReference.descriptor.identity,
      key: valueReference.key
    )
    guard let slot = slots[identity] else { return nil }
    let row = arena.index(of: slot)
    return cyclePath(ifEnteringRow: row)?.snapshot
  }

  /// Validates one raw edge row and returns its native array index.
  func liveRow(_ rawRow: Int32) -> Int {
    guard rawRow >= 0 else {
      fatalError("Cog found a negative arena state row in graph topology.")
    }
    let row = Int(rawRow)
    guard row < arena.rowCount, arena.flags[row].contains(.occupied) else {
      fatalError("Cog found a released arena state row in graph topology.")
    }
    return row
  }
}
#endif
