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
  func quotesShellValuesAndBuildsOwnedPreparationScript() throws {
    #expect(POSIXShell.quote("it's safe") == "'it'\\''s safe'")

    let script = RemoteHandoffService.preparationScript(
      origin: "git@example.com:team/project.git",
      branch: "feature/test",
      commit: String(repeating: "a", count: 40),
      destination: "/srv/feather/worktrees/project-alpha-12345678",
      controlRoot: "/srv/feather/.feather",
      configPath: "/srv/feather/.feather/tmux.conf",
      summaryPath: "/srv/feather/.feather/handoffs/session.txt",
      summary: "Ready\n",
      sessionID: "feather-session"
    )

    #expect(script.contains("test ! -e \"$destination\""))
    #expect(script.contains("git clone --no-checkout --single-branch"))
    #expect(script.contains("checkout -B 'feature/test'"))
    #expect(script.contains("tmux -L 'feather'"))
    #expect(script.contains("kill-session -t \"$session\""))
    #expect(script.contains("rm -rf -- \"$destination\""))
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
      summaryPath: "/srv/feather/.feather-dev/handoffs/session.txt",
      summary: "Ready\n",
      sessionID: "feather-session",
      tmuxSocketName: "feather-dev"
    )

    #expect(script.contains("tmux -L 'feather-dev'"))
    #expect(!script.contains("tmux -L 'feather'"))
    _ = try CommandRunner().run("/bin/sh", arguments: ["-n", "-c", script])
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
