import ArgumentParser
import CogLintCore

/// The command-line boundary for Cog's syntax-only convention checker.
///
/// The scaffold deliberately accepts no files yet; later M8 behavior slices
/// add discovery, reporters, and exit status over `CogLintCore`. Parsing an
/// empty buffer here keeps the executable linked through the same parser seam
/// those slices extend, so a package build already proves every exact pin.
@main
struct CogLintCommand: ParsableCommand {
  /// The stable shell spelling shared by the bare CLI and command plugin.
  static let configuration = CommandConfiguration(commandName: "coglint")

  /// Exercises the core parser while the behavior surface is still empty.
  mutating func run() throws {
    _ = CogLintParser.parse(source: "")
  }
}
