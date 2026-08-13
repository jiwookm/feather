import Foundation

public struct GitStatusFile: Equatable, Identifiable, Sendable {
  public var id: String { path }
  public let path: String
  public let originalPath: String?
  public let indexStatus: Character
  public let worktreeStatus: Character

  public init(
    path: String,
    originalPath: String? = nil,
    indexStatus: Character,
    worktreeStatus: Character
  ) {
    self.path = path
    self.originalPath = originalPath
    self.indexStatus = indexStatus
    self.worktreeStatus = worktreeStatus
  }

  public var isUntracked: Bool { indexStatus == "?" }
  public var isStaged: Bool { !isUntracked && indexStatus != "." }
  public var hasWorktreeChanges: Bool { isUntracked || worktreeStatus != "." }
  public var isConflicted: Bool {
    indexStatus == "U" || worktreeStatus == "U"
      || ["DD", "AU", "UD", "UA", "DU", "AA", "UU"].contains(
        String([indexStatus, worktreeStatus]))
  }
}

public struct GitStatusSnapshot: Equatable, Sendable {
  public let branch: String?
  public let upstream: String?
  public let ahead: Int
  public let behind: Int
  public let files: [GitStatusFile]
  public let isTruncated: Bool

  public init(
    branch: String? = nil,
    upstream: String? = nil,
    ahead: Int = 0,
    behind: Int = 0,
    files: [GitStatusFile] = [],
    isTruncated: Bool = false
  ) {
    self.branch = branch
    self.upstream = upstream
    self.ahead = ahead
    self.behind = behind
    self.files = files
    self.isTruncated = isTruncated
  }
}

public struct GitLineStat: Equatable, Identifiable, Sendable {
  public var id: String { path }
  public let path: String
  public let additions: Int?
  public let deletions: Int?

  public init(path: String, additions: Int?, deletions: Int?) {
    self.path = path
    self.additions = additions
    self.deletions = deletions
  }
}

public struct RepositoryReviewFile: Equatable, Identifiable, Sendable {
  public var id: String { path }
  public let path: String
  public let additions: Int?
  public let deletions: Int?
  public let isUntracked: Bool

  public init(
    path: String,
    additions: Int?,
    deletions: Int?,
    isUntracked: Bool = false
  ) {
    self.path = path
    self.additions = additions
    self.deletions = deletions
    self.isUntracked = isUntracked
  }
}

public struct RepositoryReviewSnapshot: Equatable, Sendable {
  public let baseReference: String
  public let files: [RepositoryReviewFile]
  public let isTruncated: Bool

  public init(
    baseReference: String,
    files: [RepositoryReviewFile],
    isTruncated: Bool = false
  ) {
    self.baseReference = baseReference
    self.files = files
    self.isTruncated = isTruncated
  }

  public var additions: Int { files.compactMap(\.additions).reduce(0, +) }
  public var deletions: Int { files.compactMap(\.deletions).reduce(0, +) }
}

public enum GitNumStatParser {
  public static func parse(_ data: Data) -> [GitLineStat] {
    let records = data.split(separator: 0, omittingEmptySubsequences: false)
    var stats: [GitLineStat] = []
    var index = 0

    while index < records.count {
      let record = String(decoding: records[index], as: UTF8.self)
      index += 1
      guard !record.isEmpty else { continue }
      let fields = record.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
      guard fields.count == 3 else { continue }

      var path = String(fields[2])
      if path.isEmpty, index + 1 < records.count {
        // With -z, rename records put the old and new paths in the next two fields.
        index += 1
        path = String(decoding: records[index], as: UTF8.self)
        index += 1
      }
      guard !path.isEmpty else { continue }
      stats.append(
        GitLineStat(
          path: path,
          additions: Int(fields[0]),
          deletions: Int(fields[1])
        )
      )
    }
    return stats
  }
}

public enum GitStatusParser {
  public static func parse(_ data: Data, maximumFiles: Int = 5_000) -> GitStatusSnapshot {
    let records = data.split(separator: 0, omittingEmptySubsequences: true)
    var branch: String?
    var upstream: String?
    var ahead = 0
    var behind = 0
    var files: [GitStatusFile] = []
    var truncated = false
    var index = 0

    while index < records.count {
      let record = String(decoding: records[index], as: UTF8.self)
      index += 1
      if record.hasPrefix("# branch.head ") {
        let value = String(record.dropFirst("# branch.head ".count))
        branch = value == "(detached)" ? nil : value
        continue
      }
      if record.hasPrefix("# branch.upstream ") {
        upstream = String(record.dropFirst("# branch.upstream ".count))
        continue
      }
      if record.hasPrefix("# branch.ab ") {
        let fields = record.split(separator: " ")
        for field in fields.dropFirst(2) {
          if field.first == "+" { ahead = Int(field.dropFirst()) ?? 0 }
          if field.first == "-" { behind = Int(field.dropFirst()) ?? 0 }
        }
        continue
      }
      guard files.count < maximumFiles else {
        truncated = true
        continue
      }

      if record.hasPrefix("? ") {
        files.append(
          GitStatusFile(
            path: String(record.dropFirst(2)),
            indexStatus: "?",
            worktreeStatus: "?"
          )
        )
        continue
      }
      if record.hasPrefix("1 "), let file = ordinary(record) {
        files.append(file)
        continue
      }
      if record.hasPrefix("2 "), let file = renamed(record, originalRecord: records[safe: index]) {
        files.append(file)
        if index < records.count { index += 1 }
        continue
      }
      if record.hasPrefix("u "), let file = unmerged(record) {
        files.append(file)
      }
    }

    return GitStatusSnapshot(
      branch: branch,
      upstream: upstream,
      ahead: ahead,
      behind: behind,
      files: files,
      isTruncated: truncated
    )
  }

  private static func ordinary(_ record: String) -> GitStatusFile? {
    let fields = record.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false)
    guard fields.count == 9, let status = statusPair(fields[1]) else { return nil }
    return GitStatusFile(
      path: String(fields[8]),
      indexStatus: status.0,
      worktreeStatus: status.1
    )
  }

  private static func renamed(_ record: String, originalRecord: Data.SubSequence?) -> GitStatusFile?
  {
    let fields = record.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: false)
    guard fields.count == 10, let status = statusPair(fields[1]) else { return nil }
    return GitStatusFile(
      path: String(fields[9]),
      originalPath: originalRecord.map { String(decoding: $0, as: UTF8.self) },
      indexStatus: status.0,
      worktreeStatus: status.1
    )
  }

  private static func unmerged(_ record: String) -> GitStatusFile? {
    let fields = record.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
    guard fields.count == 11, let status = statusPair(fields[1]) else { return nil }
    return GitStatusFile(
      path: String(fields[10]),
      indexStatus: status.0,
      worktreeStatus: status.1
    )
  }

  private static func statusPair(_ value: Substring) -> (Character, Character)? {
    guard value.count == 2 else { return nil }
    return (value[value.startIndex], value[value.index(after: value.startIndex)])
  }
}

extension Array {
  fileprivate subscript(safe index: Index) -> Element? {
    indices.contains(index) ? self[index] : nil
  }
}

public actor GitWorkspaceService {
  private let runner: BoundedCommandRunner
  private let gitExecutable: String

  public init(
    runner: BoundedCommandRunner = BoundedCommandRunner(),
    gitExecutable: String = "/usr/bin/git"
  ) {
    self.runner = runner
    self.gitExecutable = gitExecutable
  }

  public func status(worktreePath: String) async throws -> GitStatusSnapshot {
    let output = try await git(
      ["-C", worktreePath, "status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all"],
      timeout: 20
    )
    return GitStatusParser.parse(output.stdout)
  }

  public func diff(
    worktreePath: String,
    path: String,
    staged: Bool,
    untracked: Bool = false,
    ignoreWhitespace: Bool = false
  ) async throws -> String {
    try validateRelativePath(path)
    if untracked {
      var arguments = ["-C", worktreePath, "diff", "--no-index", "--no-color", "--unified=3"]
      if ignoreWhitespace { arguments.append("--ignore-all-space") }
      arguments += ["--", "/dev/null", path]
      let output = try await runGit(
        arguments,
        maximumOutputBytes: 1_024 * 1_024,
        timeout: 15
      )
      guard output.status == 0 || output.status == 1 else {
        throw BoundedCommandFailure(
          executable: gitExecutable,
          arguments: ["diff", "--no-index", path],
          status: output.status,
          stderr: output.stderrText
        )
      }
      return output.stdoutText
    }
    var arguments = ["-C", worktreePath, "diff", "--no-ext-diff", "--no-color", "--unified=3"]
    if staged { arguments.append("--cached") }
    if ignoreWhitespace { arguments.append("--ignore-all-space") }
    arguments += ["--", path]
    return try await git(arguments, maximumOutputBytes: 1_024 * 1_024).stdoutText
  }

  public func diffStats(worktreePath: String, staged: Bool) async throws -> [GitLineStat] {
    var arguments = ["-C", worktreePath, "diff", "--no-ext-diff", "--numstat", "-z"]
    if staged { arguments.append("--cached") }
    arguments.append("--")
    let output = try await git(arguments, maximumOutputBytes: 1_024 * 1_024)
    return GitNumStatParser.parse(output.stdout)
  }

  /// Lists local and origin-tracking branches without fetching or installing a watcher.
  public func reviewBases(worktreePath: String) async throws -> [String] {
    let output = try await git(
      [
        "-C", worktreePath, "for-each-ref", "--format=%(refname:short)",
        "refs/remotes/origin", "refs/heads",
      ],
      maximumOutputBytes: 256 * 1_024,
      timeout: 10
    )
    var seen = Set<String>()
    return output.stdoutText.split(whereSeparator: \.isNewline)
      .map(String.init)
      .filter { !$0.hasSuffix("/HEAD") && seen.insert($0).inserted }
      .prefix(200)
      .map { $0 }
  }

  public func defaultReviewBase(
    worktreePath: String,
    knownBases: [String]? = nil
  ) async throws -> String {
    let originHead = try await runGit(
      ["-C", worktreePath, "symbolic-ref", "--short", "refs/remotes/origin/HEAD"],
      maximumOutputBytes: 64 * 1_024,
      timeout: 8
    )
    if originHead.status == 0 {
      let value = originHead.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
      if !value.isEmpty { return value }
    }

    let branches: [String]
    if let knownBases {
      branches = knownBases
    } else {
      branches = try await reviewBases(worktreePath: worktreePath)
    }
    for candidate in ["origin/main", "origin/master", "main", "master"]
    where branches.contains(candidate) {
      return candidate
    }
    return branches.first ?? "HEAD"
  }

  /// Reviews the whole checkout against the merge-base of the selected branch.
  /// This includes branch commits plus current tracked edits and untracked files.
  public func repositoryReview(
    worktreePath: String,
    baseReference: String,
    maximumFiles: Int = 5_000
  ) async throws -> RepositoryReviewSnapshot {
    let baseCommit = try await reviewBaseCommit(
      worktreePath: worktreePath,
      baseReference: baseReference
    )
    async let diffOutput = git(
      ["-C", worktreePath, "diff", "--no-ext-diff", "--numstat", "-z", baseCommit, "--"],
      maximumOutputBytes: 2 * 1_024 * 1_024,
      timeout: 20
    )
    async let statusOutput = status(worktreePath: worktreePath)
    let (output, statusSnapshot) = try await (diffOutput, statusOutput)
    try Task.checkCancellation()

    let stats = GitNumStatParser.parse(output.stdout)
    var files = stats.map {
      RepositoryReviewFile(
        path: $0.path,
        additions: $0.additions,
        deletions: $0.deletions
      )
    }
    let trackedPaths = Set(files.map(\.path))
    files += statusSnapshot.files.lazy
      .filter { $0.isUntracked && !trackedPaths.contains($0.path) }
      .map {
        RepositoryReviewFile(
          path: $0.path,
          additions: nil,
          deletions: nil,
          isUntracked: true
        )
      }
    files.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    let truncated = statusSnapshot.isTruncated || files.count > maximumFiles
    return RepositoryReviewSnapshot(
      baseReference: baseReference,
      files: Array(files.prefix(maximumFiles)),
      isTruncated: truncated
    )
  }

  public func repositoryDiff(
    worktreePath: String,
    path: String,
    baseReference: String,
    untracked: Bool = false,
    ignoreWhitespace: Bool = false
  ) async throws -> String {
    try validateRelativePath(path)
    if untracked {
      return try await diff(
        worktreePath: worktreePath,
        path: path,
        staged: false,
        untracked: true,
        ignoreWhitespace: ignoreWhitespace
      )
    }
    let baseCommit = try await reviewBaseCommit(
      worktreePath: worktreePath,
      baseReference: baseReference
    )
    var arguments = [
      "-C", worktreePath, "diff", "--no-ext-diff", "--no-color", "--unified=3",
    ]
    if ignoreWhitespace { arguments.append("--ignore-all-space") }
    arguments += [baseCommit, "--", path]
    return try await git(arguments, maximumOutputBytes: 1_024 * 1_024).stdoutText
  }

  public func stage(worktreePath: String, path: String) async throws {
    try validateRelativePath(path)
    _ = try await git(["-C", worktreePath, "add", "--", path])
  }

  public func unstage(worktreePath: String, path: String) async throws {
    try validateRelativePath(path)
    _ = try await git(["-C", worktreePath, "restore", "--staged", "--", path])
  }

  public func stageAll(worktreePath: String) async throws {
    _ = try await git(["-C", worktreePath, "add", "-A"])
  }

  public func unstageAll(worktreePath: String) async throws {
    _ = try await git(["-C", worktreePath, "restore", "--staged", ":/"])
  }

  public func discardTrackedChanges(worktreePath: String, path: String) async throws {
    try validateRelativePath(path)
    _ = try await git(["-C", worktreePath, "restore", "--worktree", "--", path])
  }

  public func commit(worktreePath: String, message: String) async throws -> String {
    let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "" }
    let output = try await git(
      ["-C", worktreePath, "commit", "-m", trimmed],
      maximumOutputBytes: 2 * 1_024 * 1_024,
      timeout: 60
    )
    return output.stdoutText + output.stderrText
  }

  public func push(worktreePath: String) async throws -> String {
    let upstream = try await runGit(
      ["-C", worktreePath, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"],
      maximumOutputBytes: 64 * 1_024,
      timeout: 10
    )
    let arguments: [String]
    if upstream.status == 0 {
      arguments = ["-C", worktreePath, "push"]
    } else {
      let branch = try await git(
        ["-C", worktreePath, "branch", "--show-current"],
        maximumOutputBytes: 64 * 1_024,
        timeout: 10
      ).stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !branch.isEmpty else {
        throw BoundedCommandFailure(
          executable: gitExecutable,
          arguments: ["push"],
          status: 1,
          stderr: "A detached HEAD cannot be pushed without choosing a branch."
        )
      }
      arguments = ["-C", worktreePath, "push", "--set-upstream", "origin", branch]
    }
    let output = try await git(arguments, maximumOutputBytes: 2 * 1_024 * 1_024, timeout: 120)
    return output.stdoutText + output.stderrText
  }

  private func git(
    _ arguments: [String],
    maximumOutputBytes: Int = 8 * 1_024 * 1_024,
    timeout: TimeInterval = 15
  ) async throws -> BoundedCommandOutput {
    let output = try await runGit(
      arguments,
      maximumOutputBytes: maximumOutputBytes,
      timeout: timeout
    )
    guard output.status == 0 else {
      throw BoundedCommandFailure(
        executable: gitExecutable,
        arguments: arguments,
        status: output.status,
        stderr: output.stderrText.isEmpty ? output.stdoutText : output.stderrText
      )
    }
    return output
  }

  private func runGit(
    _ arguments: [String],
    maximumOutputBytes: Int,
    timeout: TimeInterval
  ) async throws -> BoundedCommandOutput {
    try await runner.run(
      gitExecutable,
      arguments: arguments,
      environment: ["GIT_OPTIONAL_LOCKS": "0", "GIT_TERMINAL_PROMPT": "0"],
      maximumOutputBytes: maximumOutputBytes,
      timeout: timeout
    )
  }

  private func validateRelativePath(_ path: String) throws {
    guard !path.isEmpty, !path.hasPrefix("/"),
      !path.split(separator: "/", omittingEmptySubsequences: false).contains("..")
    else {
      throw WorkspaceFileError.outsideRoot
    }
  }

  private func reviewBaseCommit(
    worktreePath: String,
    baseReference: String
  ) async throws -> String {
    try validateReference(baseReference)
    let resolved = try await git(
      ["-C", worktreePath, "rev-parse", "--verify", "\(baseReference)^{commit}"],
      maximumOutputBytes: 64 * 1_024,
      timeout: 8
    ).stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
    let mergeBase = try await git(
      ["-C", worktreePath, "merge-base", resolved, "HEAD"],
      maximumOutputBytes: 64 * 1_024,
      timeout: 8
    ).stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !mergeBase.isEmpty else {
      throw BoundedCommandFailure(
        executable: gitExecutable,
        arguments: ["merge-base", baseReference, "HEAD"],
        status: 1,
        stderr: "Git could not find a shared base for repository review."
      )
    }
    return mergeBase
  }

  private func validateReference(_ reference: String) throws {
    guard !reference.isEmpty, reference.count <= 256, !reference.hasPrefix("-"),
      reference.unicodeScalars.allSatisfy({
        !CharacterSet.whitespacesAndNewlines.contains($0)
          && !CharacterSet.controlCharacters.contains($0)
      })
    else {
      throw BoundedCommandFailure(
        executable: gitExecutable,
        arguments: ["rev-parse"],
        status: 1,
        stderr: "Invalid Git reference."
      )
    }
  }
}
