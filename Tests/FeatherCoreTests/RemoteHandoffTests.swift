import Foundation
import Testing

@testable import FeatherCore

struct RemoteHandoffTests {
  @Test
  func validatesAndNormalizesRemoteTargets() throws {
    let target = try SSHRemoteTargetValidator.validate(
      SSHRemoteTarget(host: " ubuntu@build-host ", port: 2222, rootPath: "/srv//feather/")
    )

    #expect(target.host == "ubuntu@build-host")
    #expect(target.port == 2222)
    #expect(target.rootPath == "/srv/feather")
    #expect(throws: RemoteHandoffError.invalidHost) {
      try SSHRemoteTargetValidator.validate(
        SSHRemoteTarget(host: "-oProxyCommand=bad", rootPath: "/srv/feather")
      )
    }
    #expect(throws: RemoteHandoffError.invalidRootPath) {
      try SSHRemoteTargetValidator.validate(
        SSHRemoteTarget(host: "build-host", rootPath: "/")
      )
    }
    #expect(throws: RemoteHandoffError.invalidRootPath) {
      try SSHRemoteTargetValidator.validate(
        SSHRemoteTarget(host: "build-host", rootPath: "/srv/../tmp")
      )
    }
    #expect(throws: RemoteHandoffError.invalidSession) {
      try SSHRemoteTargetValidator.validateSessionID("../../not-owned")
    }
  }

  @Test
  func validatesNamedProfilesWithoutAcceptingSecretMaterialFields() throws {
    let profile = try SSHRemoteProfileValidator.validate(
      name: " Build Mac ",
      target: SSHRemoteTarget(host: " build-host ", port: 2222, rootPath: "/srv/feather")
    )

    #expect(profile.name == "Build Mac")
    #expect(profile.target.host == "build-host")
    #expect(throws: RemoteHandoffError.invalidProfileName) {
      try SSHRemoteProfileValidator.validate(
        name: "  ",
        target: SSHRemoteTarget(host: "build-host", rootPath: "/srv/feather")
      )
    }
  }

  @Test
  func quotesShellValuesAndBuildsTransactionalHandoffScripts() throws {
    #expect(POSIXShell.quote("it's safe") == "'it'\\''s safe'")

    let state = fixtureState()
    let stage = RemoteHandoffService.stagingScript(
      origin: "git@example.com:team/project.git",
      state: state,
      manifestSHA256: String(repeating: "1", count: 64),
      archiveSHA256: String(repeating: "2", count: 64),
      bundleSHA256: String(repeating: "3", count: 64),
      transferDirectory: "/srv/feather/.feather/transfers/workspace.payload",
      stagingDirectory: "/srv/feather/.feather/transfers/workspace.partial",
      ownershipToken: "owned-token"
    )
    let finalize = RemoteHandoffService.finalizationScript(
      destination: "/srv/feather/worktrees/project-alpha-12345678",
      controlRoot: "/srv/feather/.feather",
      configPath: "/srv/feather/.feather/tmux.conf",
      markerPath: "/srv/feather/.feather/workspaces/workspace.owner",
      stagingDirectory: "/srv/feather/.feather/transfers/workspace.partial",
      ownershipToken: "owned-token",
      workspaceSessionID: "feather-workspace-1234"
    )
    let cleanup = RemoteHandoffService.cleanupTransferScript(
      transferDirectory: "/srv/feather/.feather/transfers/workspace.payload",
      stagingDirectory: "/srv/feather/.feather/transfers/workspace.partial",
      ownershipToken: "owned-token"
    )
    let rollback = RemoteHandoffService.rollbackScript(
      destination: "/srv/feather/worktrees/project-alpha-12345678",
      configPath: "/srv/feather/.feather/tmux.conf",
      markerPath: "/srv/feather/.feather/workspaces/workspace.owner",
      ownershipToken: "owned-token",
      workspaceSessionID: "feather-workspace-1234"
    )

    #expect(stage.contains("cat > \"$transfer/payload.tar\""))
    #expect(stage.contains("git clone --no-checkout"))
    #expect(stage.contains("bundle unbundle"))
    #expect(stage.contains("apply --binary --index"))
    #expect(stage.contains("remote-status.snapshot"))
    #expect(stage.contains("rm -rf -- \"$transfer\" \"$staging\""))
    #expect(stage.contains("$transfer/feather-owner"))
    #expect(stage.contains("printf 'staged:%s"))
    #expect(!stage.contains("new-session -d"))
    #expect(!stage.contains("checkout_marker="))
    #expect(finalize.contains("mv -- \"$staging\" \"$destination\""))
    #expect(finalize.contains("printf %s 'owned-token' > \"$marker\""))
    #expect(finalize.contains("printf %s 'owned-token' > \"$checkout_marker\""))
    #expect(finalize.contains("new-session -d -s \"$session\""))
    #expect(finalize.contains("printf 'active:%s"))
    #expect(cleanup.contains("$transfer/feather-owner"))
    #expect(cleanup.contains("feather-handoff/staged"))
    #expect(rollback.contains("owns_destination=0"))
    #expect(rollback.contains("owns_marker=0"))
    #expect(rollback.contains("feather-handoff/staged"))
    let verification = try #require(stage.range(of: "remote-status.snapshot"))
    let stagedClaim = try #require(
      stage.range(of: "feather-handoff/staged", options: .backwards)
    )
    #expect(verification.lowerBound < stagedClaim.lowerBound)
    _ = try CommandRunner().run("/bin/sh", arguments: ["-n", "-c", stage])
    _ = try CommandRunner().run("/bin/sh", arguments: ["-n", "-c", finalize])
    _ = try CommandRunner().run("/bin/sh", arguments: ["-n", "-c", cleanup])
    _ = try CommandRunner().run("/bin/sh", arguments: ["-n", "-c", rollback])
  }

  @Test
  func preparationScriptUsesAnIsolatedDevelopmentSocket() throws {
    let script = RemoteHandoffService.finalizationScript(
      destination: "/srv/feather/worktrees/project-alpha-12345678",
      controlRoot: "/srv/feather/.feather-dev",
      configPath: "/srv/feather/.feather-dev/tmux.conf",
      markerPath: "/srv/feather/.feather-dev/workspaces/workspace.owner",
      stagingDirectory: "/srv/feather/.feather-dev/transfers/workspace.partial",
      ownershipToken: "owned-token",
      workspaceSessionID: "feather-workspace-1234",
      tmuxSocketName: "feather-dev"
    )

    #expect(script.contains("tmux -L 'feather-dev'"))
    #expect(!script.contains("tmux -L 'feather'"))
    _ = try CommandRunner().run("/bin/sh", arguments: ["-n", "-c", script])
  }

  @Test
  func transferCleanupOnlyRemovesTokenOwnedPaths() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "feather-cleanup-ownership-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let runner = CommandRunner()
    let unownedTransfer = root.appendingPathComponent("unowned.payload", isDirectory: true)
    let unownedStaging = root.appendingPathComponent("unowned.partial", isDirectory: true)
    try FileManager.default.createDirectory(at: unownedTransfer, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: unownedStaging, withIntermediateDirectories: true)
    try Data("keep".utf8).write(to: unownedTransfer.appendingPathComponent("keep"))
    let unownedScript = RemoteHandoffService.cleanupTransferScript(
      transferDirectory: unownedTransfer.path,
      stagingDirectory: unownedStaging.path,
      ownershipToken: "owned-token"
    )

    let unowned = try runner.run(
      "/bin/sh",
      arguments: ["-c", unownedScript],
      allowFailure: true
    )
    #expect(unowned.status != 0)
    #expect(FileManager.default.fileExists(atPath: unownedTransfer.path))
    #expect(FileManager.default.fileExists(atPath: unownedStaging.path))

    let ownedTransfer = root.appendingPathComponent("owned.payload", isDirectory: true)
    let ownedStaging = root.appendingPathComponent("owned.partial", isDirectory: true)
    try FileManager.default.createDirectory(at: ownedTransfer, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: ownedStaging, withIntermediateDirectories: true)
    try Data("owned-token".utf8).write(
      to: ownedTransfer.appendingPathComponent("feather-owner")
    )
    let ownedScript = RemoteHandoffService.cleanupTransferScript(
      transferDirectory: ownedTransfer.path,
      stagingDirectory: ownedStaging.path,
      ownershipToken: "owned-token"
    )

    let owned = try runner.run("/bin/sh", arguments: ["-c", ownedScript])
    #expect(owned.status == 0)
    #expect(!FileManager.default.fileExists(atPath: ownedTransfer.path))
    #expect(!FileManager.default.fileExists(atPath: ownedStaging.path))
  }

  @Test
  func finalizationNeverRemovesAPreexistingDestination() throws {
    guard let tmux = TmuxEnvironment.locateExecutable() else { return }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "feather-finalize-collision-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let staging = root.appendingPathComponent("workspace.partial", isDirectory: true)
    let destination = root.appendingPathComponent("workspace", isDirectory: true)
    let handoff = staging.appendingPathComponent(".git/feather-handoff", isDirectory: true)
    try FileManager.default.createDirectory(at: handoff, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    try Data("owned-token".utf8).write(to: handoff.appendingPathComponent("staged"))
    let keep = destination.appendingPathComponent("keep")
    try Data("not Feather-owned".utf8).write(to: keep)
    let script = RemoteHandoffService.finalizationScript(
      destination: destination.path,
      controlRoot: root.appendingPathComponent("control").path,
      configPath: root.appendingPathComponent("control/tmux.conf").path,
      markerPath: root.appendingPathComponent("control/workspaces/workspace.owner").path,
      stagingDirectory: staging.path,
      ownershipToken: "owned-token",
      workspaceSessionID: "feather-workspace-collision"
    )

    let result = try CommandRunner().run(
      "/bin/sh",
      arguments: ["-c", script],
      environment: [
        "PATH": tmux.deletingLastPathComponent().path + ":/usr/bin:/bin"
      ],
      allowFailure: true
    )

    #expect(result.status != 0)
    #expect(FileManager.default.fileExists(atPath: keep.path))
    #expect(!FileManager.default.fileExists(atPath: staging.path))
  }

  private func fixtureState() -> RemoteHandoffStateFingerprint {
    RemoteHandoffStateFingerprint(
      branch: "feature/test",
      baseCommit: String(repeating: "a", count: 40),
      headCommit: String(repeating: "b", count: 40),
      publishedCommit: String(repeating: "a", count: 40),
      statusSHA256: String(repeating: "1", count: 64),
      indexPatchSHA256: String(repeating: "2", count: 64),
      worktreePatchSHA256: String(repeating: "3", count: 64),
      untrackedPathsSHA256: String(repeating: "4", count: 64),
      untrackedEntriesSHA256: String(repeating: "5", count: 64),
      stagedPathCount: 1,
      unstagedPathCount: 1,
      untrackedFileCount: 1,
      untrackedBytes: 12,
      unpublishedCommitCount: 1
    )
  }

  @Test
  func validatesOwnershipBeforeOperatingOnSavedRemotePaths() async throws {
    let repositoryID = UUID()
    let remote = SSHRemoteTerminal(
      target: SSHRemoteTarget(host: "build-host", rootPath: "/srv/feather"),
      workingDirectory: "/srv/feather/worktrees/project",
      tmuxConfigPath: "/srv/feather/.feather/tmux.conf"
    )
    let valid = RemoteWorkspaceRecord(
      repositoryID: repositoryID,
      worktreePath: "/tmp/project",
      profileID: nil,
      profileName: "Build Mac",
      remote: remote,
      ownership: RemoteWorkspaceOwnership(
        token: "owned-token",
        markerPath: "/srv/feather/.feather/workspaces/project.owner"
      )
    )
    try RemoteWorkspaceOwnershipValidator.validate(valid)
    let check = RemoteHandoffService.ownershipCheckScript(valid)
    #expect(check.contains("test -d '/srv/feather/worktrees/project'"))
    #expect(check.contains("'owned-token'"))
    #expect(check.contains("'/srv/feather/worktrees/project/.git/feather-owner'"))

    let unsafe = RemoteWorkspaceRecord(
      repositoryID: repositoryID,
      worktreePath: "/tmp/project",
      profileID: nil,
      profileName: "Build Mac",
      remote: remote,
      ownership: RemoteWorkspaceOwnership(
        token: "owned-token",
        markerPath: "/srv/feather/.feather/workspaces/../tmux.conf"
      )
    )
    #expect(throws: RemoteHandoffError.invalidOwnershipMetadata) {
      try RemoteWorkspaceOwnershipValidator.validate(unsafe)
    }
    let invalidManifest = RemoteWorkspaceRecord(
      repositoryID: repositoryID,
      worktreePath: "/tmp/project",
      profileID: nil,
      profileName: "Build Mac",
      remote: remote,
      ownership: valid.ownership,
      handoff: RemoteHandoffManifest(
        version: RemoteHandoffManifest.currentVersion + 1,
        state: fixtureState(),
        bundleSHA256: nil,
        artifactBytes: 1
      )
    )
    #expect(throws: RemoteHandoffError.invalidOwnershipMetadata) {
      try RemoteWorkspaceOwnershipValidator.validate(invalidManifest)
    }
    let state = try await RemoteHandoffService(sshExecutable: "/does/not/exist")
      .checkWorkspace(unsafe)
    #expect(state == .ownershipMismatch)
  }

  @Test
  func remoteTerminalBuildsAnInteractiveSSHAttachCommand() {
    let remote = SSHRemoteTerminal(
      target: SSHRemoteTarget(host: "build-host", port: 2222, rootPath: "/srv/feather"),
      workingDirectory: "/srv/feather/worktrees/project",
      tmuxConfigPath: "/srv/feather/.feather/tmux.conf"
    )

    let command = remote.attachCommand(sessionID: "feather-session")

    #expect(command.hasPrefix("'/usr/bin/ssh' '-tt' '-o' 'BatchMode=yes'"))
    #expect(command.contains("'ForwardAgent=no' '-p' '2222' '--' 'build-host'"))
    #expect(command.contains("attach-session"))
    #expect(!command.contains("new-session"))
    #expect(command.contains("feather-session"))
  }

  @Test
  func remoteBackendBuildsOrdinaryAgentLaunchCommandsInTheWorkspace() {
    let remote = SSHRemoteTerminal(
      target: SSHRemoteTarget(host: "build-host", rootPath: "/srv/feather"),
      workingDirectory: "/srv/feather/worktrees/project",
      tmuxConfigPath: "/srv/feather/.feather/tmux.conf"
    )

    let arguments = SSHTmuxBackend.launchArguments(
      "codex '--dangerously-bypass-approvals-and-sandbox'",
      sessionID: "feather-session",
      remote: remote
    )
    let command = SSHTmuxBackend.tmuxCommand(remote: remote, arguments: arguments)

    #expect(arguments.contains("/srv/feather/worktrees/project"))
    #expect(arguments.contains("/bin/sh"))
    #expect(command.contains("'new-session' '-d' '-s' 'feather-session'"))
    #expect(command.contains("codex"))
    #expect(command.contains("@feather-attention"))
    #expect(command.contains("printf"))
    #expect(command.contains("exec \"${SHELL:-/bin/sh}\" -l"))
  }

  @Test
  func unreachableWorkspaceIsOfflineWithoutDeletingItsRecord() async throws {
    let script = FileManager.default.temporaryDirectory
      .appendingPathComponent("feather-offline-ssh-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: script) }
    try "#!/bin/sh\nexit 255\n".write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    let workspace = RemoteWorkspaceRecord(
      repositoryID: UUID(),
      worktreePath: "/tmp/project",
      profileID: nil,
      profileName: "Offline Mac",
      remote: SSHRemoteTerminal(
        target: SSHRemoteTarget(host: "offline", rootPath: "/srv/feather"),
        workingDirectory: "/srv/feather/worktrees/project",
        tmuxConfigPath: "/srv/feather/.feather/tmux.conf"
      ),
      ownership: nil
    )
    let service = RemoteHandoffService(sshExecutable: script.path)

    #expect(try await service.checkWorkspace(workspace) == .offline)
    #expect(workspace.remote.workingDirectory == "/srv/feather/worktrees/project")
  }

  @Test
  func preparesAndRoutesAnOwnedWorkspaceThroughTheSSHBoundary() async throws {
    guard let tmux = TmuxEnvironment.locateExecutable() else { return }
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory
      .appendingPathComponent("feather-remote-workspace-\(UUID().uuidString)", isDirectory: true)
    let origin = root.appendingPathComponent("origin.git", isDirectory: true)
    let checkout = root.appendingPathComponent("local", isDirectory: true)
    let remoteRoot = root.appendingPathComponent("remote", isDirectory: true)
    let fakeSSH = root.appendingPathComponent("ssh")
    let disconnectMarker = root.appendingPathComponent("ssh-offline")
    let socketName = "feather-remote-test-\(UUID().uuidString.lowercased())"
    let runner = CommandRunner()
    defer {
      _ = try? runner.run(
        tmux.path,
        arguments: ["-L", socketName, "kill-server"],
        allowFailure: true
      )
      try? fileManager.removeItem(at: root)
    }

    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    _ = try runner.run("/usr/bin/git", arguments: ["init", "--bare", origin.path])
    _ = try runner.run("/usr/bin/git", arguments: ["clone", origin.path, checkout.path])
    try "fixture\n".write(
      to: checkout.appendingPathComponent("README.md"),
      atomically: true,
      encoding: .utf8
    )
    _ = try runner.run("/usr/bin/git", arguments: ["-C", checkout.path, "add", "README.md"])
    _ = try runner.run(
      "/usr/bin/git",
      arguments: [
        "-C", checkout.path,
        "-c", "user.name=Feather Tests",
        "-c", "user.email=feather-tests@example.com",
        "commit", "-m", "fixture",
      ]
    )
    _ = try runner.run(
      "/usr/bin/git",
      arguments: ["-C", checkout.path, "branch", "-M", "main"]
    )
    _ = try runner.run(
      "/usr/bin/git",
      arguments: ["-C", checkout.path, "push", "-u", "origin", "main"]
    )
    let tmuxDirectory = tmux.deletingLastPathComponent().path
    let fakeSSHContents = """
      #!/bin/sh
      if [ -e \(POSIXShell.quote(disconnectMarker.path)) ]; then exit 255; fi
      PATH=\(POSIXShell.quote(tmuxDirectory)):$PATH
      export PATH
      command=
      for argument in "$@"; do command=$argument; done
      exec /bin/sh -c "$command"
      """
    try fakeSSHContents.write(to: fakeSSH, atomically: true, encoding: .utf8)
    try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeSSH.path)

    let workspaceID = UUID()
    let service = RemoteHandoffService(
      sshExecutable: fakeSSH.path,
      controlDirectoryName: ".feather-test",
      tmuxSocketName: socketName
    )
    let preparation = try await service.prepareWorkspace(
      repository: RepositoryRecord(
        path: checkout.path,
        displayName: "fixture",
        remoteURL: origin.path
      ),
      worktreePath: checkout.path,
      workspaceID: workspaceID,
      target: SSHRemoteTarget(host: "fixture-host", rootPath: remoteRoot.path)
    )
    let workspace = RemoteWorkspaceRecord(
      id: workspaceID,
      repositoryID: UUID(),
      worktreePath: checkout.path,
      profileID: nil,
      profileName: "Fixture Host",
      remote: preparation.remote,
      ownership: preparation.ownership,
      handoff: preparation.manifest
    )

    #expect(fileManager.fileExists(atPath: preparation.ownership.markerPath))
    #expect(
      fileManager.fileExists(
        atPath: preparation.remote.workingDirectory + "/.git/feather-owner"
      )
    )
    #expect(try await service.checkWorkspace(workspace) == .connected)

    let backend = SSHTmuxBackend(remote: preparation.remote, sshExecutable: fakeSSH.path)
    try await backend.launchCommand(
      "printf remote-agent > feather-agent.txt",
      sessionID: "feather-agent",
      workingDirectory: preparation.remote.workingDirectory
    )
    let agentFile = preparation.remote.workingDirectory + "/feather-agent.txt"
    for _ in 0..<50 where !fileManager.fileExists(atPath: agentFile) {
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(fileManager.fileExists(atPath: agentFile))
    #expect(try await backend.sessionExists("feather-agent"))
    var agentState: TerminalRuntimeState?
    for _ in 0..<50 where agentState != .attention {
      agentState = try await backend.runtimeSnapshots()
        .first { $0.sessionID == "feather-agent" }?.state
      if agentState != .attention {
        try await Task.sleep(for: .milliseconds(20))
      }
    }
    #expect(agentState == .attention)
    try Data().write(to: disconnectMarker)
    let disconnectedBackend = SSHTmuxBackend(
      remote: preparation.remote,
      sshExecutable: fakeSSH.path
    )
    await #expect(throws: BoundedCommandFailure.self) {
      try await disconnectedBackend.sessionExists("feather-agent")
    }
    let survivingSession = try runner.run(
      tmux.path,
      arguments: ["-L", socketName, "has-session", "-t", "feather-agent"],
      allowFailure: true
    )
    #expect(survivingSession.status == 0)

    try fileManager.removeItem(at: disconnectMarker)
    let reconnectedBackend = SSHTmuxBackend(
      remote: preparation.remote,
      sshExecutable: fakeSSH.path
    )
    #expect(try await reconnectedBackend.sessionExists("feather-agent"))
    try await reconnectedBackend.acknowledgeAttention(sessionID: "feather-agent")
    var acknowledgedState: TerminalRuntimeState?
    for _ in 0..<50 where acknowledgedState != .shell {
      acknowledgedState = try await reconnectedBackend.runtimeSnapshots()
        .first { $0.sessionID == "feather-agent" }?.state
      if acknowledgedState != .shell {
        try await Task.sleep(for: .milliseconds(20))
      }
    }
    #expect(acknowledgedState == .shell)
    try await reconnectedBackend.killSession("feather-agent")
    #expect(
      TmuxSessionRuntimeResolver.state(
        for: "feather-agent",
        in: try await reconnectedBackend.runtimeSnapshots()
      ) == .exited
    )
    try Data("tampered manifest".utf8).write(
      to: URL(
        fileURLWithPath: preparation.remote.workingDirectory
          + "/.git/feather-handoff/manifest.json"
      )
    )
    #expect(try await service.checkWorkspace(workspace) == .ownershipMismatch)
    try await reconnectedBackend.killServer()
  }

  @Test
  func remoteBackendDoesNotTreatATransportFailureAsAMissingSession() async throws {
    let script = FileManager.default.temporaryDirectory
      .appendingPathComponent("feather-fake-ssh-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: script) }
    try "#!/bin/sh\nexit 255\n".write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    let backend = SSHTmuxBackend(
      remote: SSHRemoteTerminal(
        target: SSHRemoteTarget(host: "unreachable", rootPath: "/srv/feather"),
        workingDirectory: "/srv/feather/worktrees/project",
        tmuxConfigPath: "/srv/feather/.feather/tmux.conf"
      ),
      sshExecutable: script.path
    )

    await #expect(throws: BoundedCommandFailure.self) {
      try await backend.sessionExists("feather-session")
    }
    await #expect(throws: BoundedCommandFailure.self) {
      try await backend.killServer()
    }
    await #expect(throws: BoundedCommandFailure.self) {
      try await backend.runtimeSnapshots()
    }
    await #expect(throws: BoundedCommandFailure.self) {
      try await backend.acknowledgeAttention(sessionID: "feather-session")
    }
  }
}
