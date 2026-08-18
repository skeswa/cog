import Foundation

/// SARIF serialization over the execution's immutable reporter-neutral findings.
extension CogLintExecution {
  /// Encodes the sorted findings as one deterministic SARIF 2.1.0 log.
  package func sarifOutput() throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(SARIFDocument(findings: findings))
    return String(decoding: data, as: UTF8.self) + "\n"
  }
}

/// The SARIF root object and its single CogLint analysis run.
private struct SARIFDocument: Encodable {
  /// The canonical SARIF 2.1.0 JSON schema identifier.
  let schema = "https://json.schemastore.org/sarif-2.1.0.json"

  /// The SARIF specification version represented by this document.
  let version = "2.1.0"

  /// CogLint emits one run because one invocation has one tool and configuration.
  let runs: [SARIFRun]

  /// Maps the schema key whose leading dollar sign is not a Swift identifier.
  enum CodingKeys: String, CodingKey {
    case schema = "$schema"
    case version
    case runs
  }

  /// Creates rule descriptors and indexed results from reporter-neutral findings.
  init(findings: [CogLintFinding]) {
    let grouped = Dictionary(grouping: findings, by: \.rule)
    let rules = grouped.keys.sorted().compactMap { ruleID -> SARIFRule? in
      guard let finding = grouped[ruleID]?.first else { return nil }
      return SARIFRule(id: ruleID, helpURI: finding.helpURL.absoluteString)
    }
    let indices = Dictionary(
      uniqueKeysWithValues: rules.enumerated().map { ($0.element.id, $0.offset) })
    self.runs = [
      SARIFRun(
        tool: SARIFTool(driver: SARIFDriver(name: "coglint", rules: rules)),
        results: findings.map { SARIFResult(finding: $0, ruleIndex: indices[$0.rule] ?? 0) }
      )
    ]
  }
}

/// One invocation's tool metadata and result list.
private struct SARIFRun: Encodable {
  /// The driver and its complete rule descriptor inventory.
  let tool: SARIFTool

  /// Findings in the engine's deterministic reporter order.
  let results: [SARIFResult]
}

/// The SARIF wrapper around the CogLint driver.
private struct SARIFTool: Encodable {
  /// Metadata for the executable that produced this run.
  let driver: SARIFDriver
}

/// CogLint identity and the unique rules represented by this invocation.
private struct SARIFDriver: Encodable {
  /// The stable tool name displayed by code-scanning consumers.
  let name: String

  /// Unique rule descriptors sorted by slug for stable `ruleIndex` values.
  let rules: [SARIFRule]
}

/// One rule descriptor shared by every result carrying its slug.
private struct SARIFRule: Encodable {
  /// The stable rule slug used as the SARIF rule identifier.
  let id: String

  /// The permanent native DocC article for this rule.
  let helpURI: String

  /// Every CogLint v1 rule is an error with no configurable advisory mode.
  let defaultConfiguration = SARIFConfiguration(level: "error")

  /// Writes SARIF's lower-camel `helpUri` spelling.
  enum CodingKeys: String, CodingKey {
    case id
    case helpURI = "helpUri"
    case defaultConfiguration
  }
}

/// The fixed reporting level for one rule descriptor.
private struct SARIFConfiguration: Encodable {
  /// The SARIF level, fixed to `error` by the v1 severity decision.
  let level: String
}

/// One reporter-neutral finding expressed as a SARIF result.
private struct SARIFResult: Encodable {
  /// The stable slug joining this result to its rule descriptor.
  let ruleID: String

  /// The descriptor index within the driver rule array.
  let ruleIndex: Int

  /// The v1 severity fixed across every reporter.
  let level = "error"

  /// The rule-owned diagnostic message.
  let message: SARIFMessage

  /// The single exact physical source location for the finding.
  let locations: [SARIFLocation]

  /// Maps a finding without changing its source coordinates or diagnostic text.
  init(finding: CogLintFinding, ruleIndex: Int) {
    self.ruleID = finding.rule
    self.ruleIndex = ruleIndex
    self.message = SARIFMessage(text: finding.message)
    self.locations = [
      SARIFLocation(
        physicalLocation: SARIFPhysicalLocation(
          artifactLocation: SARIFArtifactLocation(uri: sarifURI(for: finding.path)),
          region: SARIFRegion(startLine: finding.line, startColumn: finding.column)
        )
      )
    ]
  }

  /// Writes SARIF's lower-camel `ruleId` spelling.
  enum CodingKeys: String, CodingKey {
    case ruleID = "ruleId"
    case ruleIndex
    case level
    case message
    case locations
  }
}

/// The human-readable diagnostic text for one result.
private struct SARIFMessage: Encodable {
  /// The rule message without reporter decoration or help URL duplication.
  let text: String
}

/// A result location wrapper required by the SARIF object model.
private struct SARIFLocation: Encodable {
  /// The artifact and one-based region containing the violation.
  let physicalLocation: SARIFPhysicalLocation
}

/// The source artifact and exact start region for one finding.
private struct SARIFPhysicalLocation: Encodable {
  /// The source path encoded as a relative URI reference.
  let artifactLocation: SARIFArtifactLocation

  /// The one-based line and column preserved from source conversion.
  let region: SARIFRegion
}

/// A source path represented as a SARIF URI reference.
private struct SARIFArtifactLocation: Encodable {
  /// The percent-encoded relative source path.
  let uri: String
}

/// The exact one-based start coordinate of a finding.
private struct SARIFRegion: Encodable {
  /// The physical source line.
  let startLine: Int

  /// The UTF-8 source column shared with Xcode diagnostics.
  let startColumn: Int
}

/// Percent-encodes a source path into a schema-valid relative URI reference.
private func sarifURI(for path: String) -> String {
  let allowed = CharacterSet(
    charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~/"
  )
  return path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
}
