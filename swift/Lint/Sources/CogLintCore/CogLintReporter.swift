/// A stable serialization surface supported by the bare CLI and plugins.
package enum CogLintReporter: String, CaseIterable, Sendable {
  /// Compiler-style diagnostics consumed by Xcode and ordinary terminals.
  case xcode

  /// Escaped workflow-command annotations consumed by GitHub Actions.
  case github

  /// A SARIF 2.1.0 log consumed by GitHub code scanning and other analyzers.
  case sarif
}

/// Reporter-specific views over one immutable, reporter-neutral finding.
extension CogLintFinding {
  /// Formats the finding as one fully escaped GitHub Actions error annotation.
  package var githubDescription: String {
    let data = "[\(rule)] \(message) — \(helpURL.absoluteString)"
    return
      "::error file=\(githubProperty(path)),line=\(line),col=\(column),title=\(githubProperty(rule))::\(githubData(data))"
  }
}

/// Complete reporter payloads over the execution's already sorted finding list.
extension CogLintExecution {
  /// The complete GitHub reporter payload, including its final newline when nonempty.
  package var githubOutput: String {
    guard !findings.isEmpty else { return "" }
    return findings.map(\.githubDescription).joined(separator: "\n") + "\n"
  }

  /// Serializes the execution through one selected reporter.
  package func output(for reporter: CogLintReporter) throws -> String {
    switch reporter {
    case .xcode: xcodeOutput
    case .github: githubOutput
    case .sarif: try sarifOutput()
    }
  }
}

/// Escapes annotation message data according to the GitHub workflow-command grammar.
private func githubData(_ value: String) -> String {
  value
    .replacingOccurrences(of: "%", with: "%25")
    .replacingOccurrences(of: "\r", with: "%0D")
    .replacingOccurrences(of: "\n", with: "%0A")
}

/// Escapes a workflow-command property, whose grammar also reserves colon and comma.
private func githubProperty(_ value: String) -> String {
  githubData(value)
    .replacingOccurrences(of: ":", with: "%3A")
    .replacingOccurrences(of: ",", with: "%2C")
}
