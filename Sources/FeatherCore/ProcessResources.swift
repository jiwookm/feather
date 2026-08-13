import Foundation

public struct ProcessResourceRow: Equatable, Sendable {
  public let pid: Int32
  public let parentPID: Int32
  public let residentKiB: Int
  public let cpuPercent: Double
  public let command: String

  public init(
    pid: Int32,
    parentPID: Int32,
    residentKiB: Int,
    cpuPercent: Double,
    command: String
  ) {
    self.pid = pid
    self.parentPID = parentPID
    self.residentKiB = residentKiB
    self.cpuPercent = cpuPercent
    self.command = command
  }
}

public enum ProcessResourceKind: String, CaseIterable, Sendable {
  case feather = "Feather"
  case tmux = "tmux"
  case claude = "Claude"
  case codex = "Codex"
  case child = "Shell & children"
}

public struct ProcessResourceSummary: Equatable, Identifiable, Sendable {
  public var id: ProcessResourceKind { kind }
  public let kind: ProcessResourceKind
  public let processCount: Int
  public let residentKiB: Int
  public let cpuPercent: Double

  public init(
    kind: ProcessResourceKind,
    processCount: Int,
    residentKiB: Int,
    cpuPercent: Double
  ) {
    self.kind = kind
    self.processCount = processCount
    self.residentKiB = residentKiB
    self.cpuPercent = cpuPercent
  }
}

public struct ProcessResourceSnapshot: Equatable, Sendable {
  public let summaries: [ProcessResourceSummary]

  public init(summaries: [ProcessResourceSummary]) {
    self.summaries = summaries
  }

  public var residentKiB: Int { summaries.map(\.residentKiB).reduce(0, +) }
  public var cpuPercent: Double { summaries.map(\.cpuPercent).reduce(0, +) }
}

public enum ProcessResourceParser {
  public static func parse(_ value: String) -> [ProcessResourceRow] {
    value.split(whereSeparator: \.isNewline).compactMap { line in
      let fields = line.split(
        maxSplits: 4,
        omittingEmptySubsequences: true,
        whereSeparator: \.isWhitespace
      )
      guard fields.count == 5,
        let pid = Int32(fields[0]),
        let parentPID = Int32(fields[1]),
        let residentKiB = Int(fields[2]),
        let cpuPercent = Double(fields[3])
      else { return nil }
      return ProcessResourceRow(
        pid: pid,
        parentPID: parentPID,
        residentKiB: residentKiB,
        cpuPercent: cpuPercent,
        command: String(fields[4])
      )
    }
  }

  public static func summarize(
    _ rows: [ProcessResourceRow],
    applicationPID: Int32,
    tmuxMarkers: [String] = [
      "Library/Application Support/Feather/tmux.conf",
      "Library/Application Support/Barnacle/tmux.conf",
    ]
  ) -> [ProcessResourceSummary] {
    var included = Set(
      rows.filter { row in
        row.pid == applicationPID || tmuxMarkers.contains { row.command.contains($0) }
      }.map(\.pid)
    )
    var changed = true
    while changed {
      changed = false
      for row in rows where included.contains(row.parentPID) && !included.contains(row.pid) {
        included.insert(row.pid)
        changed = true
      }
    }

    let relevant = rows.filter {
      included.contains($0.pid) && !$0.command.contains("ps -axo")
    }
    return ProcessResourceKind.allCases.compactMap { kind in
      let matching = relevant.filter { classify($0, applicationPID: applicationPID) == kind }
      guard !matching.isEmpty else { return nil }
      return ProcessResourceSummary(
        kind: kind,
        processCount: matching.count,
        residentKiB: matching.map(\.residentKiB).reduce(0, +),
        cpuPercent: matching.map(\.cpuPercent).reduce(0, +)
      )
    }
  }

  private static func classify(
    _ row: ProcessResourceRow,
    applicationPID: Int32
  ) -> ProcessResourceKind {
    let command = row.command.lowercased()
    if row.pid == applicationPID { return .feather }
    if command.contains("claude") { return .claude }
    if command.contains("codex") { return .codex }
    if command.contains("tmux") { return .tmux }
    return .child
  }
}

public actor ProcessResourceService {
  private let runner: BoundedCommandRunner

  public init(runner: BoundedCommandRunner = BoundedCommandRunner()) {
    self.runner = runner
  }

  public func snapshot(applicationPID: Int32) async throws -> ProcessResourceSnapshot {
    let output = try await runner.run(
      "/bin/ps",
      arguments: ["-axo", "pid=,ppid=,rss=,pcpu=,command="],
      maximumOutputBytes: 2 * 1_024 * 1_024,
      timeout: 4
    )
    guard output.status == 0 else {
      throw BoundedCommandFailure(
        executable: "/bin/ps",
        arguments: ["-axo"],
        status: output.status,
        stderr: output.stderrText
      )
    }
    let rows = ProcessResourceParser.parse(output.stdoutText)
    return ProcessResourceSnapshot(
      summaries: ProcessResourceParser.summarize(rows, applicationPID: applicationPID)
    )
  }
}
