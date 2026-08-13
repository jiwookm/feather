import Foundation
import Testing

@testable import FeatherCore

struct GitServiceTests {
  @Test
  func createsAndSafelyRemovesAWorktree() async throws {
    let fileManager = FileManager.default
    let temporaryRoot = fileManager.temporaryDirectory
      .appendingPathComponent("feather-git-\(UUID().uuidString)", isDirectory: true)
    let repositoryURL = temporaryRoot.appendingPathComponent("sample", isDirectory: true)
    let originURL = temporaryRoot.appendingPathComponent("origin.git", isDirectory: true)
    let publisherURL = temporaryRoot.appendingPathComponent("publisher", isDirectory: true)
    let worktreesRoot = temporaryRoot.appendingPathComponent("worktrees", isDirectory: true)
    defer { try? fileManager.removeItem(at: temporaryRoot) }

    try fileManager.createDirectory(at: repositoryURL, withIntermediateDirectories: true)
    let runner = CommandRunner()
    try runner.run("/usr/bin/git", arguments: ["init", "-b", "main", repositoryURL.path])
    try runner.run(
      "/usr/bin/git",
      arguments: ["-C", repositoryURL.path, "config", "user.name", "Feather Tests"])
    try runner.run(
      "/usr/bin/git",
      arguments: ["-C", repositoryURL.path, "config", "user.email", "tests@feather.local"])
    try Data("hello\n".utf8).write(to: repositoryURL.appendingPathComponent("README.md"))
    try runner.run("/usr/bin/git", arguments: ["-C", repositoryURL.path, "add", "README.md"])
    try runner.run(
      "/usr/bin/git", arguments: ["-C", repositoryURL.path, "commit", "-m", "Initial"])
    let localHead = try runner.run(
      "/usr/bin/git", arguments: ["-C", repositoryURL.path, "rev-parse", "HEAD"]
    ).text.trimmingCharacters(in: .whitespacesAndNewlines)

    try runner.run(
      "/usr/bin/git", arguments: ["init", "--bare", "-b", "main", originURL.path])
    try runner.run(
      "/usr/bin/git",
      arguments: ["-C", repositoryURL.path, "remote", "add", "origin", originURL.path])
    try runner.run(
      "/usr/bin/git", arguments: ["-C", repositoryURL.path, "push", "-u", "origin", "main"])

    try runner.run(
      "/usr/bin/git", arguments: ["clone", originURL.path, publisherURL.path])
    try runner.run(
      "/usr/bin/git",
      arguments: ["-C", publisherURL.path, "config", "user.name", "Feather Publisher"])
    try runner.run(
      "/usr/bin/git",
      arguments: ["-C", publisherURL.path, "config", "user.email", "publisher@feather.local"])
    try Data("new on origin\n".utf8).write(to: publisherURL.appendingPathComponent("REMOTE.md"))
    try runner.run("/usr/bin/git", arguments: ["-C", publisherURL.path, "add", "REMOTE.md"])
    try runner.run(
      "/usr/bin/git", arguments: ["-C", publisherURL.path, "commit", "-m", "Remote update"])
    try runner.run(
      "/usr/bin/git", arguments: ["-C", publisherURL.path, "push", "origin", "main"])
    let remoteHead = try runner.run(
      "/usr/bin/git", arguments: ["-C", publisherURL.path, "rev-parse", "HEAD"]
    ).text.trimmingCharacters(in: .whitespacesAndNewlines)

    let service = GitService()
    let (repository, initialWorktrees) = try await service.inspectRepository(at: repositoryURL)
    #expect(repository.path == repositoryURL.standardizedFileURL.path)
    #expect(repository.remoteURL == originURL.path)
    #expect(initialWorktrees.count == 1)
    #expect(try await service.defaultBase(repositoryPath: repository.path) == "origin/main")

    let created = try await service.acquireWorktree(
      repositoryPath: repository.path,
      worktreesRoot: worktreesRoot,
      reusablePaths: []
    )
    #expect(
      fileManager.fileExists(
        atPath: worktreesRoot.appendingPathComponent(".metadata_never_index").path
      ))
    #expect(created.branchDisplayName == "alpha")
    #expect(created.path.hasSuffix("sample/alpha"))
    #expect(try await service.isClean(worktreePath: created.path))
    let createdHead = try runner.run(
      "/usr/bin/git", arguments: ["-C", created.path, "rev-parse", "HEAD"]
    ).text.trimmingCharacters(in: .whitespacesAndNewlines)
    let unchangedLocalHead = try runner.run(
      "/usr/bin/git", arguments: ["-C", repository.path, "rev-parse", "HEAD"]
    ).text.trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(createdHead == remoteHead)
    #expect(unchangedLocalHead == localHead)

    let second = try await service.acquireWorktree(
      repositoryPath: repository.path,
      worktreesRoot: worktreesRoot,
      reusablePaths: []
    )
    #expect(second.branchDisplayName == "beta")
    try await service.removeWorktree(repositoryPath: repository.path, worktreePath: second.path)

    try Data("dirty\n".utf8).write(
      to: URL(fileURLWithPath: created.path).appendingPathComponent("dirty.txt"))
    await #expect(throws: FeatherError.dirtyWorktree(created.path)) {
      try await service.removeWorktree(repositoryPath: repository.path, worktreePath: created.path)
    }
    try fileManager.removeItem(
      at: URL(fileURLWithPath: created.path).appendingPathComponent("dirty.txt"))

    try await service.removeWorktree(repositoryPath: repository.path, worktreePath: created.path)
    #expect(
      !(try await service.listWorktrees(repositoryPath: repository.path)).contains {
        $0.path == created.path
      })
  }

  @Test
  func reusesMergedWorktreeAndPreservesIgnoredCache() async throws {
    let fileManager = FileManager.default
    let temporaryRoot = fileManager.temporaryDirectory
      .appendingPathComponent("feather-pool-\(UUID().uuidString)", isDirectory: true)
    let repositoryURL = temporaryRoot.appendingPathComponent("sample", isDirectory: true)
    let worktreesRoot = temporaryRoot.appendingPathComponent("worktrees", isDirectory: true)
    defer { try? fileManager.removeItem(at: temporaryRoot) }

    try fileManager.createDirectory(at: repositoryURL, withIntermediateDirectories: true)
    let runner = CommandRunner()
    try runner.run("/usr/bin/git", arguments: ["init", "-b", "main", repositoryURL.path])
    try runner.run(
      "/usr/bin/git",
      arguments: ["-C", repositoryURL.path, "config", "user.name", "Feather Tests"])
    try runner.run(
      "/usr/bin/git",
      arguments: ["-C", repositoryURL.path, "config", "user.email", "tests@feather.local"])
    try Data(".cache/\n".utf8).write(to: repositoryURL.appendingPathComponent(".gitignore"))
    try Data("base\n".utf8).write(to: repositoryURL.appendingPathComponent("README.md"))
    try runner.run("/usr/bin/git", arguments: ["-C", repositoryURL.path, "add", "."])
    try runner.run(
      "/usr/bin/git", arguments: ["-C", repositoryURL.path, "commit", "-m", "Initial"])

    let service = GitService()
    let created = try await service.acquireWorktree(
      repositoryPath: repositoryURL.path,
      worktreesRoot: worktreesRoot,
      reusablePaths: []
    )
    let worktreeURL = URL(fileURLWithPath: created.path)
    try Data("feature\n".utf8).write(to: worktreeURL.appendingPathComponent("FEATURE.md"))
    try runner.run("/usr/bin/git", arguments: ["-C", created.path, "add", "FEATURE.md"])
    try runner.run(
      "/usr/bin/git", arguments: ["-C", created.path, "commit", "-m", "Feature"])
    try runner.run(
      "/usr/bin/git", arguments: ["-C", repositoryURL.path, "merge", "--ff-only", "alpha"])

    let cacheURL = worktreeURL.appendingPathComponent(".cache/dependency")
    try fileManager.createDirectory(
      at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("cached\n".utf8).write(to: cacheURL)

    let prepared = try await service.prepareWorktreeForReuse(
      repositoryPath: repositoryURL.path,
      worktreePath: created.path
    )
    #expect(prepared.path == created.path)
    #expect(fileManager.fileExists(atPath: cacheURL.path))

    let reused = try await service.acquireWorktree(
      repositoryPath: repositoryURL.path,
      worktreesRoot: worktreesRoot,
      reusablePaths: [created.path]
    )
    #expect(reused.path == created.path)
    #expect(try await service.isClean(worktreePath: reused.path))

    try Data("unmerged\n".utf8).write(to: worktreeURL.appendingPathComponent("UNMERGED.md"))
    try runner.run("/usr/bin/git", arguments: ["-C", created.path, "add", "UNMERGED.md"])
    try runner.run(
      "/usr/bin/git", arguments: ["-C", created.path, "commit", "-m", "Unmerged"])
    await #expect(throws: FeatherError.worktreeNotMerged(created.path)) {
      try await service.prepareWorktreeForReuse(
        repositoryPath: repositoryURL.path,
        worktreePath: created.path
      )
    }
  }

  @Test
  func apfsClonesMatchingIgnoredNodeDependenciesIntoANewWorktree() async throws {
    let fileManager = FileManager.default
    let temporaryRoot = fileManager.temporaryDirectory
      .appendingPathComponent("feather-deps-\(UUID().uuidString)", isDirectory: true)
    let repositoryURL = temporaryRoot.appendingPathComponent("sample", isDirectory: true)
    let worktreesRoot = temporaryRoot.appendingPathComponent("worktrees", isDirectory: true)
    defer { try? fileManager.removeItem(at: temporaryRoot) }

    try fileManager.createDirectory(at: repositoryURL, withIntermediateDirectories: true)
    let runner = CommandRunner()
    try runner.run("/usr/bin/git", arguments: ["init", "-b", "main", repositoryURL.path])
    try runner.run(
      "/usr/bin/git",
      arguments: ["-C", repositoryURL.path, "config", "user.name", "Feather Tests"]
    )
    try runner.run(
      "/usr/bin/git",
      arguments: ["-C", repositoryURL.path, "config", "user.email", "tests@feather.local"]
    )
    try Data("node_modules/\n".utf8).write(
      to: repositoryURL.appendingPathComponent(".gitignore")
    )
    try Data("{\"lockfileVersion\":3}\n".utf8).write(
      to: repositoryURL.appendingPathComponent("package-lock.json")
    )
    try runner.run("/usr/bin/git", arguments: ["-C", repositoryURL.path, "add", "."])
    try runner.run(
      "/usr/bin/git", arguments: ["-C", repositoryURL.path, "commit", "-m", "Initial"]
    )

    let sourceDependency = repositoryURL.appendingPathComponent("node_modules/pkg/value.txt")
    try fileManager.createDirectory(
      at: sourceDependency.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data("source\n".utf8).write(to: sourceDependency)

    let created = try await GitService().acquireWorktree(
      repositoryPath: repositoryURL.path,
      worktreesRoot: worktreesRoot,
      reusablePaths: []
    )
    let clonedDependency = URL(fileURLWithPath: created.path)
      .appendingPathComponent("node_modules/pkg/value.txt")
    #expect(try String(contentsOf: clonedDependency, encoding: .utf8) == "source\n")

    try Data("worktree\n".utf8).write(to: clonedDependency)
    #expect(try String(contentsOf: sourceDependency, encoding: .utf8) == "source\n")
  }
}
