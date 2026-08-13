import Foundation
import Testing

@testable import FeatherCore

struct PersistenceTests {
  @Test
  func migratesLegacyApplicationSupportDirectory() throws {
    let temporaryRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("feather-migration-\(UUID().uuidString)", isDirectory: true)
    let legacyRoot = temporaryRoot.appendingPathComponent("Barnacle", isDirectory: true)
    let legacyState = legacyRoot.appendingPathComponent("state.json")
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }

    try FileManager.default.createDirectory(at: legacyRoot, withIntermediateDirectories: true)
    try Data("existing-state".utf8).write(to: legacyState)

    let result = JSONStateStore.applicationSupportURL(in: temporaryRoot)

    #expect(result.lastPathComponent == "Feather")
    #expect(
      try Data(contentsOf: result.appendingPathComponent("state.json"))
        == Data("existing-state".utf8)
    )
    #expect(!FileManager.default.fileExists(atPath: legacyRoot.path))
  }

  @Test
  func snapshotRoundTrips() throws {
    let temporaryRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("feather-state-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }

    let repository = RepositoryRecord(
      path: "/tmp/repo",
      displayName: "repo",
      remoteURL: "git@github.com:example/repo.git"
    )
    let managedWorktree = ManagedWorktreeRecord(
      repositoryID: repository.id,
      path: "/tmp/repo-feature",
      state: .available
    )
    let terminal = TerminalRecord(
      repositoryID: repository.id,
      worktreePath: repository.path,
      title: "Codex",
      order: 0
    )
    let snapshot = ApplicationSnapshot(
      repositories: [repository],
      managedWorktrees: [managedWorktree],
      terminals: [terminal],
      appearance: .dark,
      selectedRepositoryID: repository.id,
      selectedWorktreePath: repository.path,
      selectedTerminalID: terminal.id,
      sidebarVisible: false,
      inspectorVisible: true
    )
    let store = JSONStateStore(fileURL: temporaryRoot.appendingPathComponent("state.json"))

    try store.save(snapshot)

    #expect(try store.load() == snapshot)
  }

  @Test
  func loadsVersionTwoWorktreesAsActive() throws {
    let repositoryID = UUID()
    let json = """
      {
        "version": 2,
        "repositories": [],
        "managedWorktrees": [
          {
            "repositoryID": "\(repositoryID.uuidString)",
            "path": "/tmp/legacy-worktree"
          }
        ],
        "terminals": []
      }
      """

    let snapshot = try JSONDecoder().decode(
      ApplicationSnapshot.self,
      from: Data(json.utf8)
    )

    #expect(snapshot.managedWorktrees.first?.state == .active)
    #expect(snapshot.inspectorVisible == false)
  }

  @Test
  func loadsVersionOneStateWithoutManagedWorktreeMetadata() throws {
    let repositoryID = UUID()
    let json = """
      {
        "version": 1,
        "repositories": [
          {
            "id": "\(repositoryID.uuidString)",
            "path": "/tmp/legacy",
            "displayName": "legacy"
          }
        ],
        "terminals": []
      }
      """

    let snapshot = try JSONDecoder().decode(
      ApplicationSnapshot.self,
      from: Data(json.utf8)
    )

    #expect(snapshot.version == 1)
    #expect(snapshot.repositories.first?.remoteURL == nil)
    #expect(snapshot.managedWorktrees.isEmpty)
    #expect(snapshot.sidebarVisible)
  }

  @Test
  func displaysCommonRemoteURLsCompactly() {
    let ssh = RepositoryRecord(
      path: "/tmp/repo",
      displayName: "repo",
      remoteURL: "git@github.com:example/repo.git"
    )
    let https = RepositoryRecord(
      path: "/tmp/repo",
      displayName: "repo",
      remoteURL: "https://github.com/example/repo.git"
    )

    #expect(ssh.remoteDisplayName == "github.com/example/repo")
    #expect(https.remoteDisplayName == "github.com/example/repo")
  }

  @Test
  func parsesGitHubRepositoryIdentityWithoutAcceptingOtherHosts() throws {
    let https = try #require(
      GitHubRepositoryIdentity(remoteURL: "https://github.com/example/project.git")
    )
    let ssh = try #require(
      GitHubRepositoryIdentity(remoteURL: "git@github.com:example/project.git")
    )
    #expect(https == ssh)
    #expect(https.owner == "example")
    #expect(https.repository == "project")
    #expect(https.webURL.absoluteString == "https://github.com/example/project")
    #expect(GitHubRepositoryIdentity(remoteURL: "git@gitlab.com:example/project.git") == nil)
  }
}
