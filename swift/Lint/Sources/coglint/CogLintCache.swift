import CogLintCore
import CryptoKit
import Foundation

/// The on-disk result replayed when a plugin invocation sees identical inputs.
///
/// The record stores reporter output and process status together so a cached
/// violation remains a failing build with byte-for-byte identical diagnostics.
/// `hitCount` is operational evidence that an unchanged integration build
/// replayed the record rather than parsing the source again.
struct CogLintCacheRecord: Codable {
  /// The cache format version, independent of the artifact release version.
  let schemaVersion: Int

  /// The digest of rule semantics, invocation configuration, paths, and contents.
  let fingerprint: String

  /// The complete reporter payload, including its final newline when present.
  let output: String

  /// The process disposition paired with `output`.
  let exitCode: Int32

  /// The number of unchanged invocations that have replayed this record.
  var hitCount: Int
}

/// Content-addressed persistence for build-tool plugin invocations.
///
/// Cache reads never weaken correctness: the key includes every discovered
/// file path and byte plus target role, reporter, and a rule-set epoch. A miss
/// runs the ordinary engine, and callers store only when a second fingerprint
/// proves inputs did not change during that run.
enum CogLintCache {
  /// The first cache schema and rule-set epoch shipped with CogLint 0.4.
  private static let schemaVersion = 1
  private static let ruleSetEpoch = "coglint-v1-six-rules"

  /// Computes the collision-resistant identity of one complete invocation.
  static func fingerprint(
    paths: [String],
    relativeTo currentDirectory: URL,
    targetRole: CogLintTargetRole,
    reporter: CogLintReporter
  ) throws -> String {
    let files = try CogLintPathDiscovery.discover(paths: paths, relativeTo: currentDirectory)
    var hasher = SHA256()
    update(ruleSetEpoch, in: &hasher)
    update(targetRole.rawValue, in: &hasher)
    update(reporter.rawValue, in: &hasher)

    for file in files {
      update(file.displayPath, in: &hasher)
      let contents: Data
      do {
        contents = try Data(contentsOf: file.url)
      } catch {
        throw CogLintInputError(
          "cannot read Swift source \(file.displayPath): \(error.localizedDescription)"
        )
      }
      update(contents, in: &hasher)
    }

    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  /// Loads a valid record for `fingerprint`, treating stale or torn data as a miss.
  static func load(from url: URL, matching fingerprint: String) -> CogLintCacheRecord? {
    guard
      let data = try? Data(contentsOf: url),
      let record = try? JSONDecoder().decode(CogLintCacheRecord.self, from: data),
      record.schemaVersion == schemaVersion,
      record.fingerprint == fingerprint
    else {
      return nil
    }
    return record
  }

  /// Atomically writes one result so interruption cannot create a plausible hit.
  static func store(
    fingerprint: String,
    output: String,
    exitCode: Int32,
    hitCount: Int,
    at url: URL
  ) throws {
    let record = CogLintCacheRecord(
      schemaVersion: schemaVersion,
      fingerprint: fingerprint,
      output: output,
      exitCode: exitCode,
      hitCount: hitCount
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(record)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try data.write(to: url, options: .atomic)
  }

  /// Adds a length-delimited string to the fingerprint without ambiguous joins.
  private static func update(_ value: String, in hasher: inout SHA256) {
    update(Data(value.utf8), in: &hasher)
  }

  /// Adds length-delimited bytes so paths and contents cannot alias one another.
  private static func update(_ value: Data, in hasher: inout SHA256) {
    var length = UInt64(value.count).bigEndian
    withUnsafeBytes(of: &length) { hasher.update(data: Data($0)) }
    hasher.update(data: value)
  }
}
