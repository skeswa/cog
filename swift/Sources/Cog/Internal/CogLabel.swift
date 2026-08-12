/// The human-readable name of one declaration.
///
/// Cycle diagnostics and debug history print labels (§2.4, §6.5). Descriptor
/// object identity still distinguishes declarations that share a label.
///
/// A label keeps `#fileID` as a `StaticString` and renders a `String` only for
/// display. Unnamed declarations allocate no label string.
internal struct CogLabel: Sendable, CustomStringConvertible {
  /// The name the declaration passed as `name:`, or `nil` when it did not.
  let name: String?

  /// `#fileID` at the declaration site, in the form `ModuleName/File.swift`.
  ///
  /// `#fileID` is short, has no absolute path, and is stored as a constant.
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
