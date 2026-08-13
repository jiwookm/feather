import Foundation
import Testing

@testable import FeatherCore

struct GitWorkspaceServiceTests {
  @Test
  func refreshesStagesUnstagesDiscardsAndCommits() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("feather-source-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let runner = CommandRunner()
    try runner.run("/usr/bin/git", arguments: ["init", "-b", "main", root.path])
    try runner.run(
      "/usr/bin/git",
      arguments: ["-C", root.path, "config", "user.name", "Feather Tests"]
    )
    try runner.run(
      "/usr/bin/git",
      arguments: ["-C", root.path, "config", "user.email", "tests@feather.local"]
    )
    let tracked = root.appendingPathComponent("tracked.txt")
    try Data("base\n".utf8).write(to: tracked)
    try runner.run("/usr/bin/git", arguments: ["-C", root.path, "add", "."])
    try runner.run(
      "/usr/bin/git", arguments: ["-C", root.path, "commit", "-m", "Initial"]
    )

    try Data("changed\n".utf8).write(to: tracked)
    try Data("new\n".utf8).write(to: root.appendingPathComponent("new.txt"))
    let service = GitWorkspaceService()
    var status = try await service.status(worktreePath: root.path)
    #expect(status.branch == "main")
    #expect(status.files.first { $0.path == "tracked.txt" }?.hasWorktreeChanges == true)
    #expect(status.files.first { $0.path == "new.txt" }?.isUntracked == true)
    #expect(
      try await service.diffStats(worktreePath: root.path, staged: false)
        == [GitLineStat(path: "tracked.txt", additions: 1, deletions: 1)]
    )

    try await service.stage(worktreePath: root.path, path: "new.txt")
    status = try await service.status(worktreePath: root.path)
    #expect(status.files.first { $0.path == "new.txt" }?.isStaged == true)
    #expect(
      try await service.diffStats(worktreePath: root.path, staged: true)
        == [GitLineStat(path: "new.txt", additions: 1, deletions: 0)]
    )
    try await service.unstage(worktreePath: root.path, path: "new.txt")
    try await service.discardTrackedChanges(worktreePath: root.path, path: "tracked.txt")
    #expect(try String(contentsOf: tracked, encoding: .utf8) == "base\n")

    try await service.stageAll(worktreePath: root.path)
    _ = try await service.commit(worktreePath: root.path, message: "Add file")
    #expect(try await service.status(worktreePath: root.path).files.isEmpty)

    let added = root.appendingPathComponent("new.txt")
    try Data("new   \n".utf8).write(to: added)
    let visibleWhitespace = try await service.diff(
      worktreePath: root.path,
      path: "new.txt",
      staged: false
    )
    let ignoredWhitespace = try await service.diff(
      worktreePath: root.path,
      path: "new.txt",
      staged: false,
      ignoreWhitespace: true
    )
    #expect(!visibleWhitespace.isEmpty)
    #expect(ignoredWhitespace.isEmpty)
  }

  @Test
  func reviewsTheWholeBranchAgainstItsMergeBase() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("feather-review-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let runner = CommandRunner()
    try runner.run("/usr/bin/git", arguments: ["init", "-b", "main", root.path])
    try runner.run(
      "/usr/bin/git", arguments: ["-C", root.path, "config", "user.name", "Feather Tests"])
    try runner.run(
      "/usr/bin/git",
      arguments: ["-C", root.path, "config", "user.email", "tests@feather.local"])
    let committed = root.appendingPathComponent("committed.txt")
    let edited = root.appendingPathComponent("edited.txt")
    try Data("base\n".utf8).write(to: committed)
    try Data("base\n".utf8).write(to: edited)
    try runner.run("/usr/bin/git", arguments: ["-C", root.path, "add", "."])
    try runner.run("/usr/bin/git", arguments: ["-C", root.path, "commit", "-m", "Initial"])
    try runner.run("/usr/bin/git", arguments: ["-C", root.path, "switch", "-c", "feature"])
    try Data("feature\n".utf8).write(to: committed)
    try runner.run("/usr/bin/git", arguments: ["-C", root.path, "add", "committed.txt"])
    try runner.run("/usr/bin/git", arguments: ["-C", root.path, "commit", "-m", "Feature"])
    try Data("working\n".utf8).write(to: edited)
    try Data("untracked\n".utf8).write(to: root.appendingPathComponent("new.txt"))

    let service = GitWorkspaceService()
    let bases = try await service.reviewBases(worktreePath: root.path)
    #expect(bases.contains("main"))
    let review = try await service.repositoryReview(
      worktreePath: root.path,
      baseReference: "main"
    )
    #expect(review.files.map(\.path) == ["committed.txt", "edited.txt", "new.txt"])
    #expect(review.files.first { $0.path == "new.txt" }?.isUntracked == true)
    #expect(review.additions == 2)
    #expect(review.deletions == 2)

    let patch = try await service.repositoryDiff(
      worktreePath: root.path,
      path: "committed.txt",
      baseReference: "main"
    )
    #expect(patch.contains("+feature"))
  }
}
