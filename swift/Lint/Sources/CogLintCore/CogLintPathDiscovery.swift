import Foundation

/// One canonical Swift file selected from the invocation's explicit paths.
package struct CogLintSourceFile: Equatable, Sendable {
  /// The canonical absolute URL used for reading and duplicate elimination.
  package let url: URL

  /// The stable path printed in diagnostics, relative to the invocation root when possible.
  package let displayPath: String

  /// Creates one discovered file after path normalization is complete.
  package init(url: URL, displayPath: String) {
    self.url = url
    self.displayPath = displayPath
  }
}

/// A path-selection failure that must not masquerade as a clean lint run.
package struct CogLintInputError: Error, Equatable, Sendable, CustomStringConvertible {
  /// The complete user-facing explanation surfaced by argument-parser.
  package let description: String

  /// Creates a stable input diagnostic.
  package init(_ description: String) {
    self.description = description
  }
}

/// Expands explicit files and directories into one deterministic Swift file set.
package enum CogLintPathDiscovery {
  /// Discovers canonical `.swift` files beneath `paths`.
  ///
  /// Explicit files must be Swift sources, while non-Swift children of a
  /// directory are ignored. Hidden descendants and directory symlinks are not
  /// traversed, which keeps build products and cycles out of a recursive scan.
  /// A file named both directly and through a directory is emitted once.
  package static func discover(
    paths: [String],
    relativeTo currentDirectory: URL
  ) throws -> [CogLintSourceFile] {
    guard !paths.isEmpty else {
      throw CogLintInputError("at least one Swift file or directory is required")
    }

    let root = currentDirectory.standardizedFileURL.resolvingSymlinksInPath()
    var filesByCanonicalPath: [String: URL] = [:]

    for path in paths {
      let candidate =
        path.hasPrefix("/")
        ? URL(fileURLWithPath: path).standardizedFileURL
        : root.appending(path: path).standardizedFileURL
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory) else {
        throw CogLintInputError("input path does not exist: \(path)")
      }

      if isDirectory.boolValue {
        try collectSwiftFiles(in: candidate, into: &filesByCanonicalPath)
      } else {
        guard candidate.pathExtension == "swift" else {
          throw CogLintInputError("explicit input is not a Swift file: \(path)")
        }
        insert(candidate, into: &filesByCanonicalPath)
      }
    }

    return filesByCanonicalPath.values
      .map { url in
        CogLintSourceFile(url: url, displayPath: displayPath(for: url, relativeTo: root))
      }
      .sorted { lhs, rhs in lhs.displayPath < rhs.displayPath }
  }

  /// Recursively walks one directory in lexical child order without following directory symlinks.
  private static func collectSwiftFiles(
    in directory: URL,
    into filesByCanonicalPath: inout [String: URL]
  ) throws {
    let children: [URL]
    do {
      children = try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
        options: [.skipsHiddenFiles]
      ).sorted { $0.path < $1.path }
    } catch {
      throw CogLintInputError(
        "cannot read directory \(directory.path): \(error.localizedDescription)")
    }

    for child in children {
      let values: URLResourceValues
      do {
        values = try child.resourceValues(forKeys: [
          .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
        ])
      } catch {
        throw CogLintInputError("cannot inspect input \(child.path): \(error.localizedDescription)")
      }

      if values.isDirectory == true {
        if values.isSymbolicLink != true {
          try collectSwiftFiles(in: child, into: &filesByCanonicalPath)
        }
      } else if child.pathExtension == "swift" && values.isRegularFile == true {
        insert(child, into: &filesByCanonicalPath)
      }
    }
  }

  /// Adds one file under its resolved path so overlapping inputs cannot duplicate diagnostics.
  private static func insert(_ file: URL, into filesByCanonicalPath: inout [String: URL]) {
    let canonical = file.standardizedFileURL.resolvingSymlinksInPath()
    filesByCanonicalPath[canonical.path] = canonical
  }

  /// Prefers a repository-relative diagnostic while preserving files outside the invocation root.
  private static func displayPath(for file: URL, relativeTo root: URL) -> String {
    let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
    if file.path.hasPrefix(rootPath) {
      return String(file.path.dropFirst(rootPath.count))
    }
    return file.path
  }
}
