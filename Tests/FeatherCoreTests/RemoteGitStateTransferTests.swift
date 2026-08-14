import Foundation
import Testing

@testable import FeatherCore

struct RemoteGitStateTransferTests {
  @Test
  func rejectsCredentialAndUnsafeUntrackedPathsByConstruction() throws {
    try RemoteTransferPathPolicy.validate("Sources/example.swift")
    try RemoteTransferPathPolicy.validate(".env.example")
    try RemoteTransferPathPolicy.validate("fixtures/public-key.txt")

    #expect(throws: RemoteHandoffError.sensitiveUntrackedPath(".env")) {
      try RemoteTransferPathPolicy.validate(".env")
    }
    #expect(throws: RemoteHandoffError.sensitiveUntrackedPath("deploy/id_ed25519")) {
      try RemoteTransferPathPolicy.validate("deploy/id_ed25519")
    }
    #expect(throws: RemoteHandoffError.sensitiveUntrackedPath(".ssh/config")) {
      try RemoteTransferPathPolicy.validate(".ssh/config")
    }
    #expect(throws: RemoteHandoffError.sensitiveUntrackedPath("certificates/app.pem")) {
      try RemoteTransferPathPolicy.validate("certificates/app.pem")
    }
    #expect(throws: RemoteHandoffError.unsupportedUntrackedPath("../escape")) {
      try RemoteTransferPathPolicy.validate("../escape")
    }
    #expect(throws: RemoteHandoffError.unsupportedUntrackedPath("nested/.git/config")) {
      try RemoteTransferPathPolicy.validate("nested/.git/config")
    }
  }

  @Test
  func capturesPublishedThenUnpublishedDirtyStateWithoutIncludingIgnoredFiles() async throws {
    let fixture = try GitTransferFixture()
    defer { fixture.remove() }
    let transfer = RemoteGitStateTransfer(
      runner: BoundedCommandRunner(),
      gitExecutable: "/usr/bin/git"
    )

    let clean = try await transfer.buildPayload(worktreePath: fixture.checkout.path)
    #expect(clean.preflight.state.isPublishedClean)
    #expect(clean.preflight.state.unpublishedCommitCount == 0)
    #expect(clean.manifest.bundleSHA256 == nil)
    #expect(clean.preflight.transferBytes > 0)

    try fixture.write("committed\n", to: "committed.txt")
    try fixture.git(["add", "committed.txt"])
    try fixture.commit("unpublished")

    let unpublished = try await transfer.buildPayload(worktreePath: fixture.checkout.path)
    #expect(!unpublished.preflight.state.isPublishedClean)
    #expect(unpublished.preflight.state.unpublishedCommitCount == 1)
    #expect(unpublished.preflight.state.stagedPathCount == 0)
    #expect(unpublished.preflight.state.unstagedPathCount == 0)
    #expect(unpublished.preflight.state.untrackedFileCount == 0)
    #expect(unpublished.manifest.bundleSHA256 != nil)

    try fixture.write("staged\n", to: "staged.txt")
    try fixture.git(["add", "staged.txt"])
    try fixture.write("working\n", to: "tracked.txt")
    try fixture.write("untracked\n", to: "notes.txt")
    try fixture.write("ignored\n", to: "cache/ignored.txt")
    try fixture.write("#!/bin/sh\nexit 0\n", to: "script.sh", permissions: 0o755)
    try FileManager.default.createSymbolicLink(
      atPath: fixture.checkout.appendingPathComponent("notes-link").path,
      withDestinationPath: "notes.txt"
    )

    let dirty = try await transfer.buildPayload(worktreePath: fixture.checkout.path)
    #expect(!dirty.preflight.state.isPublishedClean)
    #expect(dirty.preflight.state.unpublishedCommitCount == 1)
    #expect(dirty.preflight.state.stagedPathCount == 1)
    #expect(dirty.preflight.state.unstagedPathCount == 1)
    #expect(dirty.preflight.state.untrackedFileCount == 3)
    #expect(dirty.preflight.state.untrackedBytes > 0)
    #expect(dirty.manifest.bundleSHA256 != nil)
    #expect(dirty.archive.count == Int(dirty.preflight.transferBytes))
    #expect(dirty.archiveSHA256.count == 64)
    #expect(dirty.manifestSHA256.count == 64)
  }

  @Test
  func findsThePublishedBaseForANewUnpublishedBranch() async throws {
    let fixture = try GitTransferFixture()
    defer { fixture.remove() }
    let transfer = RemoteGitStateTransfer(
      runner: BoundedCommandRunner(),
      gitExecutable: "/usr/bin/git"
    )
    let publishedMain = try fixture.git(["rev-parse", "origin/main"]).text
      .trimmingCharacters(in: .whitespacesAndNewlines)

    try fixture.git(["checkout", "-b", "topic/local-only"])
    try fixture.write("topic\n", to: "topic.txt")
    try fixture.git(["add", "topic.txt"])
    try fixture.commit("local topic")

    let payload = try await transfer.buildPayload(worktreePath: fixture.checkout.path)

    #expect(payload.preflight.state.branch == "topic/local-only")
    #expect(payload.preflight.state.publishedCommit == nil)
    #expect(payload.preflight.state.baseCommit == publishedMain)
    #expect(payload.preflight.state.unpublishedCommitCount == 1)
    #expect(payload.manifest.bundleSHA256 != nil)
  }

  @Test
  func enforcesUntrackedSizeAndCredentialBoundsBeforeTransfer() async throws {
    let oversized = try GitTransferFixture()
    defer { oversized.remove() }
    try oversized.write("12345", to: "too-large.txt")
    let limited = RemoteGitStateTransfer(
      runner: BoundedCommandRunner(),
      gitExecutable: "/usr/bin/git",
      limits: RemoteHandoffLimits(maximumUntrackedFileBytes: 4)
    )

    await #expect(
      throws: RemoteHandoffError.untrackedFileTooLarge("too-large.txt", 4)
    ) {
      try await limited.buildPayload(worktreePath: oversized.checkout.path)
    }

    let credential = try GitTransferFixture()
    defer { credential.remove() }
    try credential.write("token\n", to: ".env.local")
    let transfer = RemoteGitStateTransfer(
      runner: BoundedCommandRunner(),
      gitExecutable: "/usr/bin/git"
    )

    await #expect(throws: RemoteHandoffError.sensitiveUntrackedPath(".env.local")) {
      try await transfer.buildPayload(worktreePath: credential.checkout.path)
    }

    let credentialOrigin = try GitTransferFixture()
    defer { credentialOrigin.remove() }
    try credentialOrigin.git([
      "remote", "set-url", "origin", "https://embedded-token@example.com/project.git",
    ])
    await #expect(throws: RemoteHandoffError.credentialBearingOrigin) {
      try await transfer.buildPayload(worktreePath: credentialOrigin.checkout.path)
    }
  }

  @Test
  func transfersUnpublishedIndexWorktreeBinarySymlinkAndUntrackedStateLosslessly() async throws {
    guard let tmux = TmuxEnvironment.locateExecutable() else { return }
    let fixture = try GitTransferFixture()
    let fileManager = FileManager.default
    let fakeSSH = fixture.root.appendingPathComponent("ssh")
    let remoteRoot = fixture.root.appendingPathComponent("remote", isDirectory: true)
    let socketName = "feather-dirty-transfer-\(UUID().uuidString.lowercased())"
    let runner = CommandRunner()
    defer {
      _ = try? runner.run(
        tmux.path,
        arguments: ["-L", socketName, "kill-server"],
        allowFailure: true
      )
      fixture.remove()
    }
    try fileManager.createDirectory(at: remoteRoot, withIntermediateDirectories: true)
    try fixture.makeFakeSSH(at: fakeSSH, tmux: tmux)

    try fixture.write("committed\n", to: "committed.txt")
    try fixture.git(["add", "committed.txt"])
    try fixture.commit("unpublished")
    try fixture.write("staged value\n", to: "staged.txt")
    try fixture.git(["add", "staged.txt"])
    try fixture.git(["mv", "rename-source.txt", "renamed.txt"])
    try fixture.git(["rm", "delete.txt"])
    try fileManager.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: fixture.checkout.appendingPathComponent("mode.sh").path
    )
    try fixture.git(["add", "mode.sh"])
    try fixture.write(Data([0, 9, 8, 7, 0, 6, 255]), to: "binary.dat")
    try fixture.git(["add", "binary.dat"])
    try fileManager.removeItem(at: fixture.checkout.appendingPathComponent("tracked-link"))
    try fileManager.createSymbolicLink(
      atPath: fixture.checkout.appendingPathComponent("tracked-link").path,
      withDestinationPath: "staged.txt"
    )
    try fixture.git(["add", "tracked-link"])

    try fixture.write("staged plus working value\n", to: "staged.txt")
    try fixture.write("unstaged value\n", to: "unstaged.txt")
    try fileManager.removeItem(at: fixture.checkout.appendingPathComponent("worktree-delete.txt"))
    try fixture.write("untracked\n", to: "notes.txt")
    try fixture.write("spaced path\n", to: "notes/space name.txt")
    try fixture.write("#!/bin/sh\nexit 0\n", to: "script.sh", permissions: 0o755)
    try fileManager.createSymbolicLink(
      atPath: fixture.checkout.appendingPathComponent("notes-link").path,
      withDestinationPath: "notes.txt"
    )
    try fixture.write("ignored\n", to: "cache/dependency.txt")
    try fixture.write("secret\n", to: ".env")

    let localState = try fixture.canonicalState()
    let localHead = try fixture.git(["rev-parse", "HEAD"]).text.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    let originHeadBefore = try runner.run(
      "/usr/bin/git",
      arguments: ["--git-dir", fixture.origin.path, "rev-parse", "refs/heads/main"]
    ).text.trimmingCharacters(in: .whitespacesAndNewlines)

    let service = RemoteHandoffService(
      sshExecutable: fakeSSH.path,
      controlDirectoryName: ".feather-test",
      tmuxSocketName: socketName
    )
    let preflight = try await service.preflightWorkspace(worktreePath: fixture.checkout.path)
    #expect(preflight.state.unpublishedCommitCount == 1)
    #expect(preflight.state.stagedPathCount >= 6)
    #expect(preflight.state.unstagedPathCount >= 3)
    #expect(preflight.state.untrackedFileCount == 4)

    let workspaceID = UUID()
    let preparation = try await service.prepareWorkspace(
      repository: RepositoryRecord(
        path: fixture.checkout.path,
        displayName: "fixture",
        remoteURL: fixture.origin.path
      ),
      worktreePath: fixture.checkout.path,
      workspaceID: workspaceID,
      target: SSHRemoteTarget(host: "fixture-host", rootPath: remoteRoot.path),
      expectedPreflight: preflight
    )

    let remoteState = try fixture.canonicalState(at: preparation.remote.workingDirectory)
    #expect(remoteState == localState)
    #expect(
      try fixture.git(at: preparation.remote.workingDirectory, ["rev-parse", "HEAD"]).text
        .trimmingCharacters(in: .whitespacesAndNewlines) == localHead
    )
    #expect(
      try runner.run(
        "/usr/bin/git",
        arguments: ["--git-dir", fixture.origin.path, "rev-parse", "refs/heads/main"]
      ).text.trimmingCharacters(in: .whitespacesAndNewlines) == originHeadBefore
    )
    #expect(
      fileManager.fileExists(
        atPath: preparation.remote.workingDirectory + "/.git/feather-handoff/manifest.json"
      )
    )
    #expect(
      !fileManager.fileExists(atPath: preparation.remote.workingDirectory + "/cache/dependency.txt")
    )
    #expect(!fileManager.fileExists(atPath: preparation.remote.workingDirectory + "/.env"))
    #expect(
      try String(
        contentsOfFile: preparation.remote.workingDirectory + "/notes/space name.txt",
        encoding: .utf8
      ) == "spaced path\n"
    )
    let remoteScriptMode =
      try fileManager.attributesOfItem(
        atPath: preparation.remote.workingDirectory + "/script.sh"
      )[.posixPermissions] as? NSNumber
    #expect((remoteScriptMode?.intValue ?? 0) & 0o111 != 0)
    #expect(
      try fileManager.destinationOfSymbolicLink(
        atPath: preparation.remote.workingDirectory + "/notes-link"
      ) == "notes.txt"
    )
    let backend = SSHTmuxBackend(remote: preparation.remote, sshExecutable: fakeSSH.path)
    #expect(
      try await backend.sessionExists(RemoteHandoffService.workspaceSessionID(workspaceID))
    )
    try await backend.killServer()
  }

  @Test
  func localChangeAfterRemoteVerificationPreventsAuthorityAndRemovesStaging() async throws {
    guard let tmux = TmuxEnvironment.locateExecutable() else { return }
    let fixture = try GitTransferFixture()
    let fileManager = FileManager.default
    let fakeSSH = fixture.root.appendingPathComponent("ssh")
    let mutationMarker = fixture.root.appendingPathComponent("mutated-once")
    let remoteRoot = fixture.root.appendingPathComponent("remote", isDirectory: true)
    let remoteSocket = "feather-race-transfer-\(UUID().uuidString.lowercased())"
    let localSocket = "feather-local-survival-\(UUID().uuidString.lowercased())"
    let runner = CommandRunner()
    defer {
      _ = try? runner.run(
        tmux.path,
        arguments: ["-L", remoteSocket, "kill-server"],
        allowFailure: true
      )
      _ = try? runner.run(
        tmux.path,
        arguments: ["-L", localSocket, "kill-server"],
        allowFailure: true
      )
      fixture.remove()
    }
    try fileManager.createDirectory(at: remoteRoot, withIntermediateDirectories: true)
    try fixture.makeFakeSSH(
      at: fakeSSH,
      tmux: tmux,
      mode: .mutateAfterStaging(
        path: fixture.checkout.appendingPathComponent("tracked.txt"),
        marker: mutationMarker
      )
    )
    try runner.run(
      tmux.path,
      arguments: ["-L", localSocket, "new-session", "-d", "-s", "local-agent"]
    )

    let service = RemoteHandoffService(
      sshExecutable: fakeSSH.path,
      controlDirectoryName: ".feather-test",
      tmuxSocketName: remoteSocket
    )
    let preflight = try await service.preflightWorkspace(worktreePath: fixture.checkout.path)
    let workspaceID = UUID()
    do {
      _ = try await service.prepareWorkspace(
        repository: RepositoryRecord(
          path: fixture.checkout.path,
          displayName: "fixture",
          remoteURL: fixture.origin.path
        ),
        worktreePath: fixture.checkout.path,
        workspaceID: workspaceID,
        target: SSHRemoteTarget(host: "fixture-host", rootPath: remoteRoot.path),
        expectedPreflight: preflight
      )
      Issue.record("A changed local checkpoint must not become remote-authoritative")
    } catch {
      #expect(error as? RemoteHandoffError == .checkpointChanged(fixture.checkout.path))
    }

    let transferRoot = remoteRoot.appendingPathComponent(".feather-test/transfers")
    #expect((try? fileManager.contentsOfDirectory(atPath: transferRoot.path))?.isEmpty != false)
    #expect(!fileManager.fileExists(atPath: remoteRoot.appendingPathComponent("worktrees").path))
    #expect(
      try runner.run(
        tmux.path,
        arguments: [
          "-L", remoteSocket, "has-session", "-t",
          RemoteHandoffService.workspaceSessionID(workspaceID),
        ],
        allowFailure: true
      ).status != 0
    )
    #expect(
      try runner.run(
        tmux.path,
        arguments: ["-L", localSocket, "has-session", "-t", "local-agent"],
        allowFailure: true
      ).status == 0
    )
    #expect(
      try String(
        contentsOf: fixture.checkout.appendingPathComponent("tracked.txt"),
        encoding: .utf8
      ).contains("external change")
    )
  }

  @Test
  func interruptedPayloadLeavesNoCheckoutOwnershipOrRemoteSession() async throws {
    guard let tmux = TmuxEnvironment.locateExecutable() else { return }
    let fixture = try GitTransferFixture()
    let fileManager = FileManager.default
    let fakeSSH = fixture.root.appendingPathComponent("ssh")
    let remoteRoot = fixture.root.appendingPathComponent("remote", isDirectory: true)
    let socketName = "feather-interrupted-transfer-\(UUID().uuidString.lowercased())"
    let runner = CommandRunner()
    defer {
      _ = try? runner.run(
        tmux.path,
        arguments: ["-L", socketName, "kill-server"],
        allowFailure: true
      )
      fixture.remove()
    }
    try fileManager.createDirectory(at: remoteRoot, withIntermediateDirectories: true)
    try fixture.makeFakeSSH(at: fakeSSH, tmux: tmux, mode: .truncateStagingPayload)
    let localBefore = try fixture.git([
      "status", "--porcelain=v1", "-z", "--untracked-files=all", "--no-renames",
    ]).data
    let service = RemoteHandoffService(
      sshExecutable: fakeSSH.path,
      controlDirectoryName: ".feather-test",
      tmuxSocketName: socketName
    )
    let workspaceID = UUID()

    await #expect(throws: BoundedCommandFailure.self) {
      try await service.prepareWorkspace(
        repository: RepositoryRecord(
          path: fixture.checkout.path,
          displayName: "fixture",
          remoteURL: fixture.origin.path
        ),
        worktreePath: fixture.checkout.path,
        workspaceID: workspaceID,
        target: SSHRemoteTarget(host: "fixture-host", rootPath: remoteRoot.path)
      )
    }

    let transferRoot = remoteRoot.appendingPathComponent(".feather-test/transfers")
    #expect((try? fileManager.contentsOfDirectory(atPath: transferRoot.path))?.isEmpty != false)
    #expect(!fileManager.fileExists(atPath: remoteRoot.appendingPathComponent("worktrees").path))
    #expect(
      try runner.run(
        tmux.path,
        arguments: [
          "-L", socketName, "has-session", "-t",
          RemoteHandoffService.workspaceSessionID(workspaceID),
        ],
        allowFailure: true
      ).status != 0
    )
    #expect(
      try fixture.git([
        "status", "--porcelain=v1", "-z", "--untracked-files=all", "--no-renames",
      ]).data == localBefore
    )
  }

  @Test
  func interruptedActivationRollsBackTheVerifiedWorkspaceAndKeepsTheLocalSession() async throws {
    guard let tmux = TmuxEnvironment.locateExecutable() else { return }
    let fixture = try GitTransferFixture()
    let fileManager = FileManager.default
    let fakeSSH = fixture.root.appendingPathComponent("ssh")
    let failureMarker = fixture.root.appendingPathComponent("failed-after-activation")
    let remoteRoot = fixture.root.appendingPathComponent("remote", isDirectory: true)
    let remoteSocket = "feather-activation-interrupt-\(UUID().uuidString.lowercased())"
    let localSocket = "feather-activation-local-\(UUID().uuidString.lowercased())"
    let runner = CommandRunner()
    defer {
      _ = try? runner.run(
        tmux.path,
        arguments: ["-L", remoteSocket, "kill-server"],
        allowFailure: true
      )
      _ = try? runner.run(
        tmux.path,
        arguments: ["-L", localSocket, "kill-server"],
        allowFailure: true
      )
      fixture.remove()
    }
    try fileManager.createDirectory(at: remoteRoot, withIntermediateDirectories: true)
    try fixture.makeFakeSSH(
      at: fakeSSH,
      tmux: tmux,
      mode: .failOnceAfterActivation(marker: failureMarker)
    )
    try runner.run(
      tmux.path,
      arguments: ["-L", localSocket, "new-session", "-d", "-s", "local-agent"]
    )
    try fixture.write("local work\n", to: "notes.txt")
    let localBefore = try fixture.canonicalStatus()
    let service = RemoteHandoffService(
      sshExecutable: fakeSSH.path,
      controlDirectoryName: ".feather-test",
      tmuxSocketName: remoteSocket
    )
    let workspaceID = UUID()

    await #expect(throws: BoundedCommandFailure.self) {
      try await service.prepareWorkspace(
        repository: RepositoryRecord(
          path: fixture.checkout.path,
          displayName: "fixture",
          remoteURL: fixture.origin.path
        ),
        worktreePath: fixture.checkout.path,
        workspaceID: workspaceID,
        target: SSHRemoteTarget(host: "fixture-host", rootPath: remoteRoot.path)
      )
    }

    let worktrees = remoteRoot.appendingPathComponent("worktrees")
    let ownership = remoteRoot.appendingPathComponent(".feather-test/workspaces")
    let transfers = remoteRoot.appendingPathComponent(".feather-test/transfers")
    #expect((try? fileManager.contentsOfDirectory(atPath: worktrees.path))?.isEmpty != false)
    #expect((try? fileManager.contentsOfDirectory(atPath: ownership.path))?.isEmpty != false)
    #expect((try? fileManager.contentsOfDirectory(atPath: transfers.path))?.isEmpty != false)
    #expect(
      try runner.run(
        tmux.path,
        arguments: [
          "-L", remoteSocket, "has-session", "-t",
          RemoteHandoffService.workspaceSessionID(workspaceID),
        ],
        allowFailure: true
      ).status != 0
    )
    #expect(
      try runner.run(
        tmux.path,
        arguments: ["-L", localSocket, "has-session", "-t", "local-agent"],
        allowFailure: true
      ).status == 0
    )
    #expect(try fixture.canonicalStatus() == localBefore)
  }
}

private final class GitTransferFixture {
  let root: URL
  let origin: URL
  let checkout: URL
  private let runner = CommandRunner()

  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "Feather Git Transfer \(UUID().uuidString)",
      isDirectory: true
    )
    origin = root.appendingPathComponent("origin.git", isDirectory: true)
    checkout = root.appendingPathComponent("checkout", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try runner.run("/usr/bin/git", arguments: ["init", "--bare", origin.path])
    try runner.run("/usr/bin/git", arguments: ["clone", origin.path, checkout.path])
    try write("base\n", to: "tracked.txt")
    try write("staged base\n", to: "staged.txt")
    try write("unstaged base\n", to: "unstaged.txt")
    try write("delete me\n", to: "delete.txt")
    try write("rename me\n", to: "rename-source.txt")
    try write("worktree delete\n", to: "worktree-delete.txt")
    try write("#!/bin/sh\nexit 0\n", to: "mode.sh", permissions: 0o644)
    try write(Data([0, 1, 2, 3, 0, 255]), to: "binary.dat")
    try FileManager.default.createSymbolicLink(
      atPath: checkout.appendingPathComponent("tracked-link").path,
      withDestinationPath: "tracked.txt"
    )
    try write("cache/\n.env\n", to: ".gitignore")
    try git(["add", "."])
    try commit("base")
    try git(["branch", "-M", "main"])
    try git(["push", "-u", "origin", "main"])
    try runner.run(
      "/usr/bin/git",
      arguments: ["--git-dir", origin.path, "symbolic-ref", "HEAD", "refs/heads/main"]
    )
    try git(["remote", "set-head", "origin", "main"])
  }

  func write(_ value: String, to path: String, permissions: Int? = nil) throws {
    try write(Data(value.utf8), to: path, permissions: permissions)
  }

  func write(_ value: Data, to path: String, permissions: Int? = nil) throws {
    let url = checkout.appendingPathComponent(path)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try value.write(to: url)
    if let permissions {
      try FileManager.default.setAttributes(
        [.posixPermissions: permissions],
        ofItemAtPath: url.path
      )
    }
  }

  @discardableResult
  func git(_ arguments: [String]) throws -> CommandOutput {
    try git(at: checkout.path, arguments)
  }

  @discardableResult
  func git(at path: String, _ arguments: [String]) throws -> CommandOutput {
    try runner.run("/usr/bin/git", arguments: ["-C", path] + arguments)
  }

  func commit(_ message: String) throws {
    try git([
      "-c", "user.name=Feather Tests",
      "-c", "user.email=feather-tests@example.com",
      "commit", "-m", message,
    ])
  }

  func makeFakeSSH(
    at url: URL,
    tmux: URL,
    mode: FakeSSHMode = .normal
  ) throws {
    let behavior: String
    switch mode {
    case .normal:
      behavior = "exec /bin/sh -c \"$command\""
    case .mutateAfterStaging(let path, let marker):
      behavior = """
        /bin/sh -c "$command"
        status=$?
        case "$command" in
          *payload.tar*)
            if [ "$status" -eq 0 ] && [ ! -e \(POSIXShell.quote(marker.path)) ]; then
              printf '\\nexternal change\\n' >> \(POSIXShell.quote(path.path))
              touch \(POSIXShell.quote(marker.path))
            fi
            ;;
        esac
        exit "$status"
        """
    case .truncateStagingPayload:
      behavior = """
        case "$command" in
          *payload.tar*) exec dd bs=128 count=1 2>/dev/null | /bin/sh -c "$command" ;;
          *) exec /bin/sh -c "$command" ;;
        esac
        """
    case .failOnceAfterActivation(let marker):
      behavior = """
        /bin/sh -c "$command"
        status=$?
        case "$command" in
          *new-session*)
            if [ "$status" -eq 0 ] && [ ! -e \(POSIXShell.quote(marker.path)) ]; then
              touch \(POSIXShell.quote(marker.path))
              exit 255
            fi
            ;;
        esac
        exit "$status"
        """
    }
    let contents = """
      #!/bin/sh
      PATH=\(POSIXShell.quote(tmux.deletingLastPathComponent().path)):$PATH
      export PATH
      command=
      for argument in "$@"; do command=$argument; done
      \(behavior)
      """
    try Data(contents.utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
  }

  func canonicalState(at path: String? = nil) throws -> CanonicalGitState {
    let path = path ?? checkout.path
    let diffPrefix = [
      "-c", "diff.mnemonicPrefix=false",
      "-c", "diff.noprefix=false",
      "diff", "--binary", "--full-index", "--no-color", "--no-ext-diff", "--no-textconv",
      "--no-renames", "--src-prefix=a/", "--dst-prefix=b/",
    ]
    let indexPatch = try git(at: path, diffPrefix + ["--cached"]).data
    let worktreePatch = try git(at: path, diffPrefix).data
    let status = try git(
      at: path,
      [
        "status", "--porcelain=v1", "-z", "--untracked-files=all", "--no-renames",
      ]
    ).data
    let untrackedPaths = try git(
      at: path,
      [
        "ls-files", "--others", "--exclude-standard", "-z",
      ]
    ).data
    let root = URL(fileURLWithPath: path, isDirectory: true)
    let notes = try Data(contentsOf: root.appendingPathComponent("notes.txt"))
    let script = try Data(contentsOf: root.appendingPathComponent("script.sh"))
    let linkTarget = try FileManager.default.destinationOfSymbolicLink(
      atPath: root.appendingPathComponent("notes-link").path
    )
    let permissions =
      try FileManager.default.attributesOfItem(
        atPath: root.appendingPathComponent("script.sh").path
      )[.posixPermissions] as? NSNumber
    return CanonicalGitState(
      status: status,
      indexPatch: indexPatch,
      worktreePatch: worktreePatch,
      untrackedPaths: untrackedPaths,
      notes: notes,
      script: script,
      linkTarget: linkTarget,
      scriptIsExecutable: (permissions?.intValue ?? 0) & 0o111 != 0
    )
  }

  func canonicalStatus() throws -> Data {
    try git([
      "status", "--porcelain=v1", "-z", "--untracked-files=all", "--no-renames",
    ]).data
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }
}

private enum FakeSSHMode {
  case normal
  case mutateAfterStaging(path: URL, marker: URL)
  case truncateStagingPayload
  case failOnceAfterActivation(marker: URL)
}

private struct CanonicalGitState: Equatable {
  let status: Data
  let indexPatch: Data
  let worktreePatch: Data
  let untrackedPaths: Data
  let notes: Data
  let script: Data
  let linkTarget: String
  let scriptIsExecutable: Bool
}
