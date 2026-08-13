import Foundation

public enum QuickOpenPathParser {
  public static func parse(_ data: Data, maximumFiles: Int = 50_000) -> [String] {
    data.split(separator: 0, omittingEmptySubsequences: true)
      .prefix(maximumFiles)
      .map { String(decoding: $0, as: UTF8.self) }
  }
}

public enum QuickOpenMatcher {
  public static func matches(
    _ paths: [String],
    query: String,
    limit: Int = 100
  ) -> [String] {
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !needle.isEmpty else { return Array(paths.prefix(limit)) }

    var ranked: [(String, Int)] = []
    ranked.reserveCapacity(min(paths.count, 2_048))
    for (index, path) in paths.enumerated() {
      if index.isMultiple(of: 1_024), Task.isCancelled { return [] }
      guard let score = score(path: path, query: needle) else { continue }
      ranked.append((path, score))
    }
    return ranked.sorted {
      $0.1 == $1.1
        ? $0.0.localizedStandardCompare($1.0) == .orderedAscending
        : $0.1 < $1.1
    }
    .prefix(limit)
    .map(\.0)
  }

  private static func score(path: String, query: String) -> Int? {
    let candidate = path.lowercased()
    let basename = URL(fileURLWithPath: path).lastPathComponent.lowercased()
    if basename == query { return 0 }
    if basename.hasPrefix(query) { return 10 + basename.count - query.count }
    if let range = basename.range(of: query) {
      return 30 + basename.distance(from: basename.startIndex, to: range.lowerBound)
    }
    if let range = candidate.range(of: query) {
      return 80 + candidate.distance(from: candidate.startIndex, to: range.lowerBound)
    }

    var queryIndex = query.startIndex
    var previousMatch: String.Index?
    var gaps = 0
    for index in candidate.indices where queryIndex < query.endIndex {
      guard candidate[index] == query[queryIndex] else { continue }
      if let previousMatch {
        gaps += candidate.distance(from: candidate.index(after: previousMatch), to: index)
      }
      previousMatch = index
      query.formIndex(after: &queryIndex)
    }
    return queryIndex == query.endIndex ? 160 + gaps + candidate.count / 4 : nil
  }
}

public actor QuickOpenService {
  private let runner: BoundedCommandRunner
  private let gitExecutable: String

  public init(
    runner: BoundedCommandRunner = BoundedCommandRunner(),
    gitExecutable: String = "/usr/bin/git"
  ) {
    self.runner = runner
    self.gitExecutable = gitExecutable
  }

  public func files(worktreePath: String) async throws -> [String] {
    let output = try await runner.run(
      gitExecutable,
      arguments: [
        "-C", worktreePath, "ls-files", "-z", "--cached", "--others", "--exclude-standard",
      ],
      environment: ["GIT_OPTIONAL_LOCKS": "0", "GIT_TERMINAL_PROMPT": "0"],
      maximumOutputBytes: 4 * 1_024 * 1_024,
      timeout: 12
    )
    guard output.status == 0 else {
      throw BoundedCommandFailure(
        executable: gitExecutable,
        arguments: ["ls-files"],
        status: output.status,
        stderr: output.stderrText
      )
    }
    return QuickOpenPathParser.parse(output.stdout)
  }
}
