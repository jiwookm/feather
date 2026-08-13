import Foundation

public struct RepositorySearchMatch: Equatable, Identifiable, Sendable {
  public var id: String { "\(path):\(line):\(column)" }
  public let path: String
  public let line: Int
  public let column: Int
  public let preview: String

  public init(path: String, line: Int, column: Int, preview: String) {
    self.path = path
    self.line = line
    self.column = column
    self.preview = preview
  }
}

public struct RepositorySearchSnapshot: Equatable, Sendable {
  public let matches: [RepositorySearchMatch]
  public let isTruncated: Bool

  public init(matches: [RepositorySearchMatch], isTruncated: Bool) {
    self.matches = matches
    self.isTruncated = isTruncated
  }
}

enum RepositorySearchError: LocalizedError, Equatable, Sendable {
  case ripgrepUnavailable

  var errorDescription: String? {
    switch self {
    case .ripgrepUnavailable:
      "Repository search requires ripgrep. Install it with `brew install ripgrep`."
    }
  }
}

enum RipgrepJSONParser {
  static func parse(_ data: Data, maximumResults: Int = 200)
    -> RepositorySearchSnapshot
  {
    let limit = max(1, maximumResults)
    let decoder = JSONDecoder()
    var matches: [RepositorySearchMatch] = []
    var totalMatches = 0

    for line in data.split(whereSeparator: { $0 == 0x0A }) {
      guard let event = try? decoder.decode(RipgrepEvent.self, from: Data(line)),
        event.type == "match",
        let path = event.data?.path?.text,
        let preview = event.data?.lines?.text,
        let lineNumber = event.data?.lineNumber,
        let firstMatch = event.data?.submatches?.first
      else { continue }

      totalMatches += 1
      guard matches.count < limit else { continue }
      matches.append(
        RepositorySearchMatch(
          path: path.hasPrefix("./") ? String(path.dropFirst(2)) : path,
          line: lineNumber,
          column: firstMatch.start + 1,
          preview: preview.trimmingCharacters(in: .newlines)
        )
      )
    }

    return RepositorySearchSnapshot(matches: matches, isTruncated: totalMatches > limit)
  }

  private struct RipgrepEvent: Decodable {
    let type: String
    let data: MatchData?
  }

  private struct MatchData: Decodable {
    let path: TextValue?
    let lines: TextValue?
    let lineNumber: Int?
    let submatches: [Submatch]?

    private enum CodingKeys: String, CodingKey {
      case path
      case lines
      case lineNumber = "line_number"
      case submatches
    }
  }

  private struct TextValue: Decodable {
    let text: String?
  }

  private struct Submatch: Decodable {
    let start: Int
  }
}

public actor RepositorySearchService {
  private let runner: BoundedCommandRunner
  private let ripgrepExecutable: String?

  public init(
    runner: BoundedCommandRunner = BoundedCommandRunner(),
    ripgrepExecutable: String? = RepositorySearchService.locateExecutable()
  ) {
    self.runner = runner
    self.ripgrepExecutable = ripgrepExecutable
  }

  public func search(
    worktreePath: String,
    query: String,
    maximumResults: Int = 200
  ) async throws -> RepositorySearchSnapshot {
    guard let ripgrepExecutable else { throw RepositorySearchError.ripgrepUnavailable }
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard needle.count >= 2 else {
      return RepositorySearchSnapshot(matches: [], isTruncated: false)
    }

    let output = try await runner.run(
      ripgrepExecutable,
      arguments: [
        "--json", "--fixed-strings", "--smart-case", "--line-number", "--column",
        "--hidden", "--glob", "!.git", "--max-filesize", "2M", "--max-count", "20",
        "--threads", "2", "--", needle, ".",
      ],
      currentDirectory: URL(fileURLWithPath: worktreePath),
      environment: ["RIPGREP_CONFIG_PATH": "/dev/null"],
      maximumOutputBytes: 2 * 1_024 * 1_024,
      timeout: 10
    )
    guard output.status == 0 || output.status == 1 else {
      throw BoundedCommandFailure(
        executable: ripgrepExecutable,
        arguments: ["--fixed-strings", needle],
        status: output.status,
        stderr: output.stderrText
      )
    }
    return RipgrepJSONParser.parse(output.stdout, maximumResults: maximumResults)
  }

  public static func locateExecutable(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    fileManager: FileManager = .default
  ) -> String? {
    let fixed = ["/opt/homebrew/bin/rg", "/usr/local/bin/rg"]
    let path = (environment["PATH"] ?? "")
      .split(separator: ":")
      .map { String($0) + "/rg" }
    return (fixed + path).first { fileManager.isExecutableFile(atPath: $0) }
  }
}
