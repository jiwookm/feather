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
  func isolatedApplicationSupportDoesNotMoveProductionData() throws {
    let temporaryRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("feather-isolation-\(UUID().uuidString)", isDirectory: true)
    let productionRoot = temporaryRoot.appendingPathComponent("Feather", isDirectory: true)
    let productionState = productionRoot.appendingPathComponent("state.json")
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }

    try FileManager.default.createDirectory(
      at: productionRoot,
      withIntermediateDirectories: true
    )
    try Data("production-state".utf8).write(to: productionState)

    let result = JSONStateStore.applicationSupportURL(
      in: temporaryRoot,
      directoryName: "Feather Dev",
      legacyDirectoryName: nil
    )

    #expect(result == temporaryRoot.appendingPathComponent("Feather Dev", isDirectory: true))
    #expect(!FileManager.default.fileExists(atPath: result.path))
    #expect(try Data(contentsOf: productionState) == Data("production-state".utf8))
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
      order: 0,
      executionTarget: .ssh(
        SSHRemoteTerminal(
          target: SSHRemoteTarget(
            host: "build-host",
            port: 2222,
            rootPath: "/srv/feather"
          ),
          workingDirectory: "/srv/feather/worktrees/repo",
          tmuxConfigPath: "/srv/feather/.feather/tmux.conf"
        )
      )
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
      inspectorVisible: true,
      remoteTarget: SSHRemoteTarget(
        host: "build-host",
        port: 2222,
        rootPath: "/srv/feather"
      )
    )
    let store = JSONStateStore(fileURL: temporaryRoot.appendingPathComponent("state.json"))

    try store.save(snapshot)

    let loaded = try store.load()
    #expect(loaded == snapshot)
    #expect(loaded.terminals.first?.executionTarget == .local)
    #expect(loaded.remoteProfiles.map(\.name) == ["build-host"])
    #expect(loaded.remoteWorkspaces.count == 1)
    #expect(
      WorkspaceExecutionRouter.target(
        for: try #require(loaded.terminals.first),
        in: loaded.remoteWorkspaces
      ) == terminal.executionTarget
    )
  }

  @Test
  func migratesPerTerminalSSHMetadataToOneWorkspaceAuthority() throws {
    let repositoryID = UUID()
    let remote = SSHRemoteTerminal(
      target: SSHRemoteTarget(host: "build-host", rootPath: "/srv/feather"),
      workingDirectory: "/srv/feather/worktrees/project",
      tmuxConfigPath: "/srv/feather/.feather/tmux.conf"
    )
    let remoteTerminal = TerminalRecord(
      repositoryID: repositoryID,
      worktreePath: "/tmp/project",
      title: "Claude",
      order: 0,
      executionTarget: .ssh(remote)
    )
    let sibling = TerminalRecord(
      repositoryID: repositoryID,
      worktreePath: "/tmp/project",
      title: "Codex",
      order: 1
    )

    let snapshot = ApplicationSnapshot(terminals: [remoteTerminal, sibling])

    #expect(snapshot.remoteWorkspaces.count == 1)
    #expect(snapshot.terminals.allSatisfy { $0.executionTarget == .local })
    for terminal in snapshot.terminals {
      #expect(
        WorkspaceExecutionRouter.target(for: terminal, in: snapshot.remoteWorkspaces)
          == .ssh(remote))
    }
  }

  @Test
  func persistsOwnedRemoteWorkspaceMetadata() throws {
    let profile = SSHRemoteProfile(
      name: "Build Mac",
      target: SSHRemoteTarget(host: "build-host", rootPath: "/srv/feather")
    )
    let repositoryID = UUID()
    let workspace = RemoteWorkspaceRecord(
      repositoryID: repositoryID,
      worktreePath: "/tmp/project",
      profileID: profile.id,
      profileName: profile.name,
      remote: SSHRemoteTerminal(
        target: profile.target,
        workingDirectory: "/srv/feather/worktrees/project",
        tmuxConfigPath: "/srv/feather/.feather/tmux.conf"
      ),
      ownership: RemoteWorkspaceOwnership(
        token: "owned-token",
        markerPath: "/srv/feather/.feather/workspaces/project.owner"
      )
    )
    let snapshot = ApplicationSnapshot(
      remoteProfiles: [profile],
      selectedRemoteProfileID: profile.id,
      remoteWorkspaces: [workspace, workspace]
    )

    let data = try JSONEncoder().encode(snapshot)
    let loaded = try JSONDecoder().decode(ApplicationSnapshot.self, from: data)

    #expect(loaded.remoteProfiles == [profile])
    #expect(loaded.selectedRemoteProfileID == profile.id)
    #expect(loaded.remoteWorkspaces == [workspace])
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
    #expect(snapshot.remoteTarget == SSHRemoteTarget())
    #expect(snapshot.remoteProfiles.isEmpty)
    #expect(snapshot.remoteWorkspaces.isEmpty)
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
    #expect(snapshot.terminals.allSatisfy { $0.executionTarget == .local })
  }

  @Test
  func loadsLegacyTerminalAsLocal() throws {
    let repositoryID = UUID()
    let terminalID = UUID()
    let json = """
      {
        "version": 4,
        "repositories": [],
        "managedWorktrees": [],
        "terminals": [
          {
            "id": "\(terminalID.uuidString)",
            "repositoryID": "\(repositoryID.uuidString)",
            "worktreePath": "/tmp/legacy",
            "title": "Codex",
            "order": 0,
            "tmuxSessionID": "feather-legacy"
          }
        ]
      }
      """

    let snapshot = try JSONDecoder().decode(
      ApplicationSnapshot.self,
      from: Data(json.utf8)
    )

    #expect(snapshot.terminals.first?.executionTarget == .local)
    #expect(snapshot.remoteTarget == SSHRemoteTarget())
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
