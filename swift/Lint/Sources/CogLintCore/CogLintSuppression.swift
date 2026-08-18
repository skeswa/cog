import Foundation

/// The report action selected for one rule violation on one physical line.
package enum CogLintSuppressionDecision: Equatable, Sendable {
  /// Keep the original violation unchanged.
  case report

  /// Omit the violation because an exact directive names it on the prior line.
  case suppress

  /// Keep the violation and teach the accepted syntax after a malformed attempt.
  case reportMalformedDirective
}

/// An immutable per-file index of exact and malformed next-line directives.
///
/// The index is built from physical source lines rather than syntax trivia so
/// blank lines and comments consume the one-line reach exactly as written.
package struct CogLintSuppressionIndex: Sendable {
  /// Valid rule names keyed by the one-based physical line they may suppress.
  private let validRulesByLine: [Int: String]

  /// Malformed attempts keyed by their next line for explanatory diagnostics.
  private let malformedByLine: [Int: MalformedDirective]

  /// Parses every standalone line-comment directive in `source` once.
  package init(source: String) {
    var validRulesByLine: [Int: String] = [:]
    var malformedByLine: [Int: MalformedDirective] = [:]

    for (offset, line) in physicalLines(in: source).enumerated() {
      let affectedLine = offset + 2
      switch parseDirective(on: line) {
      case .none:
        break
      case .valid(let rule):
        validRulesByLine[affectedLine] = rule
      case .malformed(let target):
        malformedByLine[affectedLine] = MalformedDirective(target: target)
      }
    }

    self.validRulesByLine = validRulesByLine
    self.malformedByLine = malformedByLine
  }

  /// Selects whether `rule` should report a violation on `line`.
  package func decision(for rule: String, on line: Int) -> CogLintSuppressionDecision {
    if validRulesByLine[line] == rule {
      return .suppress
    }
    if let malformed = malformedByLine[line],
      malformed.target == nil || malformed.target == rule
    {
      return .reportMalformedDirective
    }
    return .report
  }
}

/// The optional rule token recovered from an otherwise invalid directive.
private struct MalformedDirective: Sendable {
  /// `nil` means the attempt supplied no usable target, so any next-line finding teaches the form.
  let target: String?
}

/// The syntactic result of examining one physical source line.
private enum ParsedDirective {
  /// The line is not attempting a CogLint suppression.
  case none

  /// The line exactly names one rule and carries a non-empty reason.
  case valid(rule: String)

  /// The line attempts the directive but violates its accepted grammar.
  case malformed(target: String?)
}

/// Parses the exact directive while recovering a target from malformed attempts.
private func parseDirective(on line: String) -> ParsedDirective {
  let indentationStripped = line.drop(while: { $0 == " " || $0 == "\t" })
  guard indentationStripped.hasPrefix("//") else { return .none }

  let comment = indentationStripped.dropFirst(2)
  let detectionText = comment.drop(while: { $0 == " " || $0 == "\t" })
  let keyword = "coglint:disable-next-line"
  guard detectionText.hasPrefix(keyword) else { return .none }

  let keywordEnd = detectionText.index(detectionText.startIndex, offsetBy: keyword.count)
  if keywordEnd != detectionText.endIndex,
    detectionText[keywordEnd] != " ", detectionText[keywordEnd] != "\t"
  {
    return .none
  }

  let recoveredTarget = recoverTarget(after: keywordEnd, in: detectionText).flatMap { target in
    isRuleSlug(target) ? target : nil
  }
  let exactPrefix = "// coglint:disable-next-line "
  guard indentationStripped.hasPrefix(exactPrefix) else {
    return .malformed(target: recoveredTarget)
  }

  let payload = indentationStripped.dropFirst(exactPrefix.count)
  guard let separator = payload.range(of: " -- ") else {
    return .malformed(target: recoveredTarget)
  }

  let rule = String(payload[..<separator.lowerBound])
  let reason = payload[separator.upperBound...]
  guard isRuleSlug(rule), reason.contains(where: { !$0.isWhitespace }) else {
    return .malformed(target: recoveredTarget)
  }
  return .valid(rule: rule)
}

/// Recovers the first whitespace-delimited target after the directive keyword.
private func recoverTarget(
  after keywordEnd: Substring.Index,
  in text: Substring
) -> String? {
  let remainder = text[keywordEnd...].drop(while: { $0 == " " || $0 == "\t" })
  guard let target = remainder.split(whereSeparator: \Character.isWhitespace).first,
    target != "--"
  else {
    return nil
  }
  return String(target)
}

/// Accepts the lowercase ASCII kebab-case used by stable CogLint rule slugs.
private func isRuleSlug(_ candidate: String) -> Bool {
  let pieces = candidate.split(separator: "-", omittingEmptySubsequences: false)
  guard !pieces.isEmpty, pieces.allSatisfy({ !$0.isEmpty }) else { return false }
  return pieces.allSatisfy { piece in
    piece.utf8.allSatisfy { byte in
      (0x61...0x7A).contains(byte) || (0x30...0x39).contains(byte)
    }
  }
}

/// Splits LF, CRLF, and bare-CR buffers without treating CRLF as two lines.
private func physicalLines(in source: String) -> [String] {
  var lines: [String] = []
  var current: [UInt8] = []
  var skipLeadingLF = false

  for byte in source.utf8 {
    if skipLeadingLF {
      skipLeadingLF = false
      if byte == 0x0A { continue }
    }
    if byte == 0x0D {
      lines.append(String(decoding: current, as: UTF8.self))
      current.removeAll(keepingCapacity: true)
      skipLeadingLF = true
    } else if byte == 0x0A {
      lines.append(String(decoding: current, as: UTF8.self))
      current.removeAll(keepingCapacity: true)
    } else {
      current.append(byte)
    }
  }
  lines.append(String(decoding: current, as: UTF8.self))
  return lines
}
