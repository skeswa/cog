/// The human-readable name of one declaration.
///
/// A label is what Cog says out loud about a cog: the descriptor-and-key path
/// in a cycle diagnostic (§2.4) and the entries in the debug history log
/// (§6.5). It is a name only. Identity is the descriptor object
/// (``CogDescriptor``), so two declarations that happen to share a label are
/// still two different cogs.
///
/// A label keeps what the declaration site captured and renders a `String`
/// only when something is actually printed. That ordering is the point: every
/// declaration in an app builds a label while approximately none of them is
/// ever printed, so declaring must not cost an allocation or any string work.
/// `#fileID` arrives as a `StaticString` — a compile-time constant with no
/// ARC and no heap — and an unnamed declaration stores nothing else. Being a
/// small `Sendable` value also means a debug-history record can carry a label
/// by copy and render it at display time rather than at record time.
internal struct CogLabel: Sendable, CustomStringConvertible {
  /// The name the declaration passed as `name:`, or `nil` when it did not.
  let name: String?

  /// `#fileID` at the declaration site, in the form `ModuleName/File.swift`.
  ///
  /// `#fileID` rather than `#file`: it is short enough to print, stable across
  /// machines because it holds no absolute path, and it is the form the
  /// compiler stores as a constant.
  let fileID: StaticString

  /// `#line` at the declaration site.
  let line: UInt

  /// Captures a declaration site, with the name it gave if it gave one.
  init(name: String?, fileID: StaticString, line: UInt) {
    self.name = name
    self.fileID = fileID
    self.line = line
  }

  /// The label as Cog prints it: the explicit name, else `fileID:line`.
  var description: String {
    if let name {
      return name
    }
    return "\(fileID):\(line)"
  }
}
