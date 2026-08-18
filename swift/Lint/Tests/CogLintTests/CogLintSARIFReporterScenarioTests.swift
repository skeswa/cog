import CogLintCore
import Foundation
import Testing

// MARK: - LINT-16

/// Proves the typed SARIF document has valid required structure and exact finding mappings.
@Test func `LINT-16 SARIF reporter emits schema-valid rules and regions`() throws {
  let findings = CogLintRuleRegistry.all.enumerated().map { index, rule in
    CogLintFinding(
      path: index == 0 ? "Sources/Café Rule 0.swift" : "Sources/Rule \(index).swift",
      line: index + 2,
      column: index + 5,
      rule: rule.slug,
      message: "message for \(rule.slug)",
      helpURL: rule.helpURL
    )
  }
  let execution = CogLintExecution(findings: findings)
  let output = try execution.output(for: .sarif)
  let root = try #require(
    JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any]
  )

  #expect(sarifValidationFailures(in: root).isEmpty)
  #expect(root["$schema"] as? String == "https://json.schemastore.org/sarif-2.1.0.json")
  #expect(root["version"] as? String == "2.1.0")

  let runs = try #require(root["runs"] as? [[String: Any]])
  let run = try #require(runs.first)
  let tool = try #require(run["tool"] as? [String: Any])
  let driver = try #require(tool["driver"] as? [String: Any])
  let rules = try #require(driver["rules"] as? [[String: Any]])
  let results = try #require(run["results"] as? [[String: Any]])

  let helpByRule: [String: String] = Dictionary(
    uniqueKeysWithValues: rules.compactMap { descriptor -> (String, String)? in
      guard let id = descriptor["id"] as? String,
        let helpURI = descriptor["helpUri"] as? String
      else { return nil }
      return (id, helpURI)
    })
  #expect(
    helpByRule
      == Dictionary(
        uniqueKeysWithValues: CogLintRuleRegistry.all.map {
          ($0.slug, $0.helpURL.absoluteString)
        })
  )

  for (index, result) in results.enumerated() {
    let locations = try #require(result["locations"] as? [[String: Any]])
    let location = try #require(locations.first)
    let physical = try #require(location["physicalLocation"] as? [String: Any])
    let artifact = try #require(physical["artifactLocation"] as? [String: Any])
    let region = try #require(physical["region"] as? [String: Any])
    let expectedURI =
      index == 0 ? "Sources/Caf%C3%A9%20Rule%200.swift" : "Sources/Rule%20\(index).swift"
    #expect(artifact["uri"] as? String == expectedURI)
    #expect(region["startLine"] as? Int == index + 2)
    #expect(region["startColumn"] as? Int == index + 5)
    #expect(result["level"] as? String == "error")
  }
}

/// Checks the required SARIF 2.1.0 object graph and every rule-index relationship.
private func sarifValidationFailures(in root: [String: Any]) -> [String] {
  var failures: [String] = []
  guard root["$schema"] is String, root["version"] as? String == "2.1.0",
    let runs = root["runs"] as? [[String: Any]], runs.count == 1,
    let run = runs.first,
    let tool = run["tool"] as? [String: Any],
    let driver = tool["driver"] as? [String: Any],
    driver["name"] as? String == "coglint",
    let rules = driver["rules"] as? [[String: Any]],
    let results = run["results"] as? [[String: Any]]
  else {
    return ["missing required SARIF root, run, or driver structure"]
  }

  for (index, rule) in rules.enumerated() {
    guard rule["id"] is String, rule["helpUri"] is String,
      let configuration = rule["defaultConfiguration"] as? [String: Any],
      configuration["level"] as? String == "error"
    else {
      failures.append("rule descriptor \(index) is incomplete")
      continue
    }
  }

  for (index, result) in results.enumerated() {
    guard let ruleID = result["ruleId"] as? String,
      let ruleIndex = result["ruleIndex"] as? Int,
      rules.indices.contains(ruleIndex),
      rules[ruleIndex]["id"] as? String == ruleID,
      result["level"] as? String == "error",
      let message = result["message"] as? [String: Any], message["text"] is String,
      let locations = result["locations"] as? [[String: Any]], locations.count == 1,
      let physical = locations.first?["physicalLocation"] as? [String: Any],
      let artifact = physical["artifactLocation"] as? [String: Any], artifact["uri"] is String,
      let region = physical["region"] as? [String: Any],
      (region["startLine"] as? Int ?? 0) > 0,
      (region["startColumn"] as? Int ?? 0) > 0
    else {
      failures.append("result \(index) is not a complete indexed physical error")
      continue
    }
  }
  return failures
}
