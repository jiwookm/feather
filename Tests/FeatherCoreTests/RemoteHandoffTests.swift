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
  func quotesShellValuesAndBuildsOwnedPreparationScript() throws {
    #expect(POSIXShell.quote("it's safe") == "'it'\\''s safe'")

    let script = RemoteHandoffService.preparationScript(
      origin: "git@example.com:team/project.git",
      branch: "feature/test",
      commit: String(repeating: "a", count: 40),
      destination: "/srv/feather/worktrees/project-alpha-12345678",
      controlRoot: "/srv/feather/.feather",
      configPath: "/srv/feather/.feather/tmux.conf",
      markerPath: "/srv/feather/.feather/workspaces/workspace.owner",
      ownershipToken: "owned-token",
      workspaceSessionID: "feather-workspace-1234"
    )

    #expect(script.contains("test ! -e \"$destination\""))
    #expect(script.contains("git clone --no-checkout --single-branch"))
    #expect(script.contains("checkout -B 'feature/test'"))
    #expect(script.contains("tmux -L 'feather'"))
    #expect(script.contains("kill-session -t \"$session\""))
    #expect(script.contains("rm -rf -- \"$destination\""))
    #expect(script.contains("printf %s 'owned-token' > \"$marker\""))
    #expect(script.contains("printf %s 'owned-token' > \"$checkout_marker\""))
    #expect(script.contains("new-session -d -s \"$session\""))
    let ownershipCheck = try #require(script.range(of: "test ! -e \"$destination\""))
    let ownershipClaim = try #require(script.range(of: "destination_created=1"))
    #expect(ownershipCheck.lowerBound < ownershipClaim.lowerBound)
    _ = try CommandRunner().run("/bin/sh", arguments: ["-n", "-c", script])
  }

  @Test
  func preparationScriptUsesAnIsolatedDevelopmentSocket() throws {
    let script = RemoteHandoffService.preparationScript(
      origin: "git@example.com:team/project.git",
      branch: "feature/test",
      commit: String(repeating: "a", count: 40),
      destination: "/srv/feather/worktrees/project-alpha-12345678",
      controlRoot: "/srv/feather/.feather-dev",
      configPath: "/srv/feather/.feather-dev/tmux.conf",
      markerPath: "/srv/feather/.feather-dev/workspaces/workspace.owner",
      ownershipToken: "owned-token",
      workspaceSessionID: "feather-workspace-1234",
      tmuxSocketName: "feather-dev"
    )

    #expect(script.contains("tmux -L 'feather-dev'"))
    #expect(!script.contains("tmux -L 'feather'"))
    _ = try CommandRunner().run("/bin/sh", arguments: ["-n", "-c", script])
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
    #expect(command.contains("new-session"))
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
      ownership: preparation.ownership
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
    try await backend.killServer()
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
  }
}
