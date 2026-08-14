import Foundation

enum RemoteHandoffError: LocalizedError, Equatable, Sendable {
  case invalidProfileName
  case invalidHost
  case invalidPort
  case invalidRootPath
  case invalidSession
  case invalidOwnershipMetadata
  case dirtyWorktree(String)
  case detachedHead
  case missingOrigin
  case unpublishedCommit(String)
  case checkpointChanged(String)

  var errorDescription: String? {
    switch self {
    case .invalidProfileName:
      "Enter a name for this SSH profile."
    case .invalidHost:
      "Enter an SSH host or alias using letters, numbers, `.`, `-`, `_`, `@`, `:`, or brackets."
    case .invalidPort:
      "The SSH port must be between 1 and 65535."
    case .invalidRootPath:
      "The remote root must be an absolute path below `/`, without `.` or `..` components."
    case .invalidSession:
      "This terminal has invalid session metadata. Recreate the terminal before using it remotely."
    case .invalidOwnershipMetadata:
      "The saved remote workspace ownership metadata is invalid. Feather will not operate on it."
    case .dirtyWorktree(let path):
      "Remote workspace setup requires a clean worktree: \(path)"
    case .detachedHead:
      "Remote workspace setup requires a named Git branch."
    case .missingOrigin:
      "Remote workspace setup requires an `origin` remote."
    case .unpublishedCommit(let branch):
      "Push `\(branch)` first. Feather only hands off a commit that exactly matches `origin`."
    case .checkpointChanged(let path):
      "The local checkpoint changed while Feather prepared the remote workspace. Nothing was made authoritative: \(path)"
    }
  }
}

public struct RemoteWorkspacePreparation: Equatable, Sendable {
  public let remote: SSHRemoteTerminal
  public let ownership: RemoteWorkspaceOwnership

  public init(remote: SSHRemoteTerminal, ownership: RemoteWorkspaceOwnership) {
    self.remote = remote
    self.ownership = ownership
  }
}

public enum SSHRemoteTargetValidator {
  public static func validate(_ target: SSHRemoteTarget) throws -> SSHRemoteTarget {
    let host = target.host.trimmingCharacters(in: .whitespacesAndNewlines)
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-@[]:"))
    guard !host.isEmpty, !host.hasPrefix("-"), host.unicodeScalars.allSatisfy(allowed.contains)
    else { throw RemoteHandoffError.invalidHost }
    guard (1...65_535).contains(target.port) else { throw RemoteHandoffError.invalidPort }

    let root = target.rootPath.trimmingCharacters(in: .whitespacesAndNewlines)
    let components = root.split(separator: "/", omittingEmptySubsequences: true)
    guard root.hasPrefix("/"), root != "/", !root.contains("\0"), !root.contains("\n"),
      !components.contains("."), !components.contains("..")
    else { throw RemoteHandoffError.invalidRootPath }

    return SSHRemoteTarget(
      host: host,
      port: target.port,
      rootPath: "/" + components.joined(separator: "/")
    )
  }

  static func validateSessionID(_ value: String) throws -> String {
    let allowed = CharacterSet(
      charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"
    )
    guard !value.isEmpty, value.utf8.count <= 128,
      value.unicodeScalars.allSatisfy(allowed.contains)
    else { throw RemoteHandoffError.invalidSession }
    return value
  }
}

public enum SSHRemoteProfileValidator {
  public static func validate(
    id: UUID = UUID(),
    name: String,
    target: SSHRemoteTarget
  ) throws -> SSHRemoteProfile {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty,
      name.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
    else {
      throw RemoteHandoffError.invalidProfileName
    }
    return SSHRemoteProfile(
      id: id,
      name: name,
      target: try SSHRemoteTargetValidator.validate(target)
    )
  }
}

public enum RemoteWorkspaceOwnershipValidator {
  public static func validate(_ workspace: RemoteWorkspaceRecord) throws {
    let target = try SSHRemoteTargetValidator.validate(workspace.remote.target)
    let controlRoot = (workspace.remote.tmuxConfigPath as NSString).deletingLastPathComponent
    let worktreesRoot = target.rootPath + "/worktrees"
    let ownershipRoot = controlRoot + "/workspaces"
    let controlName = (controlRoot as NSString).lastPathComponent
    guard target == workspace.remote.target,
      isStrictDescendant(workspace.remote.workingDirectory, of: worktreesRoot),
      (workspace.remote.workingDirectory as NSString).deletingLastPathComponent == worktreesRoot,
      isStrictDescendant(controlRoot, of: target.rootPath),
      (controlRoot as NSString).deletingLastPathComponent == target.rootPath,
      controlName == ".feather" || controlName.hasPrefix(".feather-"),
      (workspace.remote.tmuxConfigPath as NSString).lastPathComponent == "tmux.conf",
      !workspace.profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      workspace.profileName.unicodeScalars.allSatisfy({
        !CharacterSet.controlCharacters.contains($0)
      })
    else { throw RemoteHandoffError.invalidOwnershipMetadata }

    guard let ownership = workspace.ownership else { return }
    let tokenCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
    guard !ownership.token.isEmpty, ownership.token.utf8.count <= 128,
      ownership.token.unicodeScalars.allSatisfy(tokenCharacters.contains),
      isStrictDescendant(ownership.markerPath, of: ownershipRoot),
      (ownership.markerPath as NSString).deletingLastPathComponent == ownershipRoot,
      (ownership.markerPath as NSString).pathExtension == "owner"
    else { throw RemoteHandoffError.invalidOwnershipMetadata }
  }

  private static func isStrictDescendant(_ path: String, of parent: String) -> Bool {
    guard path.hasPrefix("/"), parent.hasPrefix("/") else { return false }
    let pathComponents = path.split(separator: "/", omittingEmptySubsequences: true)
    let parentComponents = parent.split(separator: "/", omittingEmptySubsequences: true)
    guard pathComponents.count > parentComponents.count,
      !pathComponents.contains("."), !pathComponents.contains("..")
    else { return false }
    return pathComponents.starts(with: parentComponents)
  }
}

enum POSIXShell {
  static func quote(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
  }
}

public actor RemoteHandoffService {
  private let runner: BoundedCommandRunner
  private let gitExecutable: String
  private let sshExecutable: String
  private let controlDirectoryName: String
  private let tmuxSocketName: String

  public init(
    runner: BoundedCommandRunner = BoundedCommandRunner(),
    gitExecutable: String = "/usr/bin/git",
    sshExecutable: String = "/usr/bin/ssh",
    controlDirectoryName: String = ".feather",
    tmuxSocketName: String = "feather"
  ) {
    self.runner = runner
    self.gitExecutable = gitExecutable
    self.sshExecutable = sshExecutable
    self.controlDirectoryName = controlDirectoryName
    self.tmuxSocketName = tmuxSocketName
  }

  public func prepareWorkspace(
    repository: RepositoryRecord,
    worktreePath: String,
    workspaceID: UUID,
    target: SSHRemoteTarget
  ) async throws -> RemoteWorkspacePreparation {
    let target = try SSHRemoteTargetValidator.validate(target)
    let status = try await git(
      ["-C", worktreePath, "status", "--porcelain=v1", "-z", "--untracked-files=all"],
      timeout: 15
    )
    guard status.stdout.isEmpty else { throw RemoteHandoffError.dirtyWorktree(worktreePath) }

    let branchOutput = try await git(
      ["-C", worktreePath, "symbolic-ref", "--quiet", "--short", "HEAD"],
      allowFailure: true
    )
    let branch = branchOutput.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard branchOutput.status == 0, !branch.isEmpty else { throw RemoteHandoffError.detachedHead }

    let commit = try await git(
      ["-C", worktreePath, "rev-parse", "--verify", "HEAD^{commit}"]
    ).stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
    let originOutput = try await git(
      ["-C", worktreePath, "remote", "get-url", "origin"],
      allowFailure: true
    )
    let origin = originOutput.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard originOutput.status == 0, !origin.isEmpty else { throw RemoteHandoffError.missingOrigin }

    let remoteRef = try await git(
      ["-C", worktreePath, "ls-remote", "--exit-code", "origin", "refs/heads/\(branch)"],
      allowFailure: true,
      timeout: 30
    )
    if remoteRef.status != 0, remoteRef.status != 2 {
      throw BoundedCommandFailure(
        executable: gitExecutable,
        arguments: ["-C", worktreePath, "ls-remote", "origin"],
        status: remoteRef.status,
        stderr: remoteRef.stderrText
      )
    }
    let publishedCommit = remoteRef.stdoutText.split(whereSeparator: \.isWhitespace).first.map(
      String.init)
    guard remoteRef.status == 0, publishedCommit == commit else {
      throw RemoteHandoffError.unpublishedCommit(branch)
    }

    let suffix = workspaceID.uuidString.lowercased().prefix(8)
    let repositoryName = Self.slug(repository.displayName)
    let worktreeName = Self.slug(URL(fileURLWithPath: worktreePath).lastPathComponent)
    let destination = "\(target.rootPath)/worktrees/\(repositoryName)-\(worktreeName)-\(suffix)"
    let controlRoot = "\(target.rootPath)/\(controlDirectoryName)"
    let configPath = "\(controlRoot)/tmux.conf"
    let markerPath = "\(controlRoot)/workspaces/\(workspaceID.uuidString.lowercased()).owner"
    let ownershipToken = UUID().uuidString.lowercased()
    let workspaceSessionID = Self.workspaceSessionID(workspaceID)
    let script = Self.preparationScript(
      origin: origin,
      branch: branch,
      commit: commit,
      destination: destination,
      controlRoot: controlRoot,
      configPath: configPath,
      markerPath: markerPath,
      ownershipToken: ownershipToken,
      workspaceSessionID: workspaceSessionID,
      tmuxSocketName: tmuxSocketName
    )

    let remote = try await runner.run(
      sshExecutable,
      arguments: Self.noninteractiveSSHArguments(target: target) + [target.host, script],
      environment: ["GIT_TERMINAL_PROMPT": "0"],
      maximumOutputBytes: 512 * 1_024,
      timeout: 120
    )
    guard remote.status == 0 else {
      throw BoundedCommandFailure(
        executable: sshExecutable,
        arguments: [target.host, "prepare Feather workspace"],
        status: remote.status,
        stderr: remote.stderrText
      )
    }

    let finalStatus = try await git(
      ["-C", worktreePath, "status", "--porcelain=v1", "-z", "--untracked-files=all"],
      timeout: 15
    )
    let finalBranch = try await git(
      ["-C", worktreePath, "symbolic-ref", "--quiet", "--short", "HEAD"],
      allowFailure: true
    )
    let finalCommit = try await git(
      ["-C", worktreePath, "rev-parse", "--verify", "HEAD^{commit}"],
      allowFailure: true
    )
    guard finalStatus.stdout.isEmpty, finalBranch.status == 0, finalCommit.status == 0,
      finalBranch.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines) == branch,
      finalCommit.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines) == commit
    else { throw RemoteHandoffError.checkpointChanged(worktreePath) }

    let remoteTerminal = SSHRemoteTerminal(
      target: target,
      workingDirectory: destination,
      tmuxConfigPath: configPath,
      tmuxSocketName: tmuxSocketName
    )
    return RemoteWorkspacePreparation(
      remote: remoteTerminal,
      ownership: RemoteWorkspaceOwnership(token: ownershipToken, markerPath: markerPath)
    )
  }

  public func checkWorkspace(
    _ workspace: RemoteWorkspaceRecord
  ) async throws -> RemoteWorkspaceRuntimeState {
    do {
      try RemoteWorkspaceOwnershipValidator.validate(workspace)
    } catch {
      return .ownershipMismatch
    }
    let script = Self.ownershipCheckScript(workspace)
    let output = try await runner.run(
      sshExecutable,
      arguments: Self.noninteractiveSSHArguments(target: workspace.remote.target) + [
        workspace.remote.target.host, script,
      ],
      maximumOutputBytes: 128 * 1_024,
      timeout: 15
    )
    switch output.status {
    case 0:
      return .connected
    case 42:
      return .ownershipMismatch
    case 255:
      return .offline
    default:
      throw BoundedCommandFailure(
        executable: sshExecutable,
        arguments: [workspace.remote.target.host, "verify Feather workspace"],
        status: output.status,
        stderr: output.stderrText
      )
    }
  }

  public func checkTarget(_ target: SSHRemoteTarget) async throws {
    let target = try SSHRemoteTargetValidator.validate(target)
    let output = try await runner.run(
      sshExecutable,
      arguments: Self.noninteractiveSSHArguments(target: target) + [
        target.host, "command -v git >/dev/null && command -v tmux >/dev/null",
      ],
      maximumOutputBytes: 128 * 1_024,
      timeout: 15
    )
    guard output.status == 0 else {
      throw BoundedCommandFailure(
        executable: sshExecutable,
        arguments: [target.host, "check git and tmux"],
        status: output.status,
        stderr: output.stderrText
      )
    }
  }

  static func preparationScript(
    origin: String,
    branch: String,
    commit: String,
    destination: String,
    controlRoot: String,
    configPath: String,
    markerPath: String,
    ownershipToken: String,
    workspaceSessionID: String,
    tmuxSocketName: String = "feather"
  ) -> String {
    let parent = (destination as NSString).deletingLastPathComponent
    let markerDirectory = (markerPath as NSString).deletingLastPathComponent
    return """
      set -eu
      destination=\(POSIXShell.quote(destination))
      marker=\(POSIXShell.quote(markerPath))
      checkout_marker="$destination/.git/feather-owner"
      session=\(POSIXShell.quote(workspaceSessionID))
      cleanup=1
      destination_created=0
      session_created=0
      cleanup_handoff() {
        status=$?
        trap - EXIT HUP INT TERM
        if [ "$cleanup" -eq 1 ] && [ "$session_created" -eq 1 ]; then
          tmux -L \(POSIXShell.quote(tmuxSocketName)) -f \(POSIXShell.quote(configPath)) kill-session -t "$session" >/dev/null 2>&1 || true
        fi
        if [ "$cleanup" -eq 1 ] && [ "$destination_created" -eq 1 ]; then
          rm -rf -- "$destination"
        fi
        if [ "$cleanup" -eq 1 ]; then
          rm -f -- "$marker" "$checkout_marker"
        fi
        exit "$status"
      }
      trap cleanup_handoff EXIT HUP INT TERM
      command -v git >/dev/null
      command -v tmux >/dev/null
      command -v base64 >/dev/null
      test ! -e "$destination"
      ! tmux -L \(POSIXShell.quote(tmuxSocketName)) -f \(POSIXShell.quote(configPath)) has-session -t "$session" >/dev/null 2>&1
      umask 077
      mkdir -p -- \(POSIXShell.quote(parent)) \(POSIXShell.quote(controlRoot)) \(POSIXShell.quote(markerDirectory))
      printf %s \(POSIXShell.quote(Data(remoteTmuxConfiguration.utf8).base64EncodedString())) | base64 -d > \(POSIXShell.quote(configPath))
      destination_created=1
      git clone --no-checkout --single-branch --branch \(POSIXShell.quote(branch)) -- \(POSIXShell.quote(origin)) "$destination"
      git -C "$destination" checkout -B \(POSIXShell.quote(branch)) \(POSIXShell.quote(commit))
      test "$(git -C "$destination" rev-parse --verify HEAD^{commit})" = \(POSIXShell.quote(commit))
      test -z "$(git -C "$destination" status --porcelain=v1 --untracked-files=all)"
      printf %s \(POSIXShell.quote(ownershipToken)) > "$marker"
      printf %s \(POSIXShell.quote(ownershipToken)) > "$checkout_marker"
      test "$(cat -- "$marker")" = \(POSIXShell.quote(ownershipToken))
      test "$(cat -- "$checkout_marker")" = \(POSIXShell.quote(ownershipToken))
      session_created=1
      tmux -L \(POSIXShell.quote(tmuxSocketName)) -f \(POSIXShell.quote(configPath)) new-session -d -s "$session" -c "$destination"
      cleanup=0
      trap - EXIT HUP INT TERM
      """
  }

  static func ownershipCheckScript(_ workspace: RemoteWorkspaceRecord) -> String {
    let directory = POSIXShell.quote(workspace.remote.workingDirectory)
    guard let ownership = workspace.ownership else {
      return "test -d \(directory) || exit 42"
    }
    let checkoutMarker = workspace.remote.workingDirectory + "/.git/feather-owner"
    return """
      test -d \(directory) || exit 42
      test -f \(POSIXShell.quote(ownership.markerPath)) || exit 42
      test "$(cat -- \(POSIXShell.quote(ownership.markerPath)))" = \(POSIXShell.quote(ownership.token)) || exit 42
      test -f \(POSIXShell.quote(checkoutMarker)) || exit 42
      test "$(cat -- \(POSIXShell.quote(checkoutMarker)))" = \(POSIXShell.quote(ownership.token)) || exit 42
      """
  }

  private func git(
    _ arguments: [String],
    allowFailure: Bool = false,
    timeout: TimeInterval = 12
  ) async throws -> BoundedCommandOutput {
    let output = try await runner.run(
      gitExecutable,
      arguments: arguments,
      environment: ["GIT_OPTIONAL_LOCKS": "0", "GIT_TERMINAL_PROMPT": "0"],
      maximumOutputBytes: 512 * 1_024,
      timeout: timeout
    )
    if !allowFailure, output.status != 0 {
      throw BoundedCommandFailure(
        executable: gitExecutable,
        arguments: arguments,
        status: output.status,
        stderr: output.stderrText
      )
    }
    return output
  }

  private static func noninteractiveSSHArguments(target: SSHRemoteTarget) -> [String] {
    [
      "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-o", "ForwardAgent=no",
      "-p", String(target.port), "--",
    ]
  }

  private static func slug(_ value: String) -> String {
    let scalars = value.lowercased().unicodeScalars.map { scalar -> Character in
      CharacterSet.alphanumerics.contains(scalar) || "-_.".unicodeScalars.contains(scalar)
        ? Character(String(scalar)) : "-"
    }
    let value = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "-."))
    return value.isEmpty ? "repository" : String(value.prefix(60))
  }

  static func workspaceSessionID(_ workspaceID: UUID) -> String {
    "feather-workspace-"
      + workspaceID.uuidString.lowercased().replacingOccurrences(of: "-", with: "")
  }

  private static let remoteTmuxConfiguration = """
    # Managed by Feather. Personal tmux configuration is intentionally not loaded.
    set -g default-terminal "tmux-256color"
    set -g focus-events on
    set -g mouse on
    set -g status off
    set -g history-limit 10000
    set -g set-clipboard on
    set -g allow-passthrough on
    set -g detach-on-destroy on
    set -g pane-border-style "fg=colour8"
    set -g pane-active-border-style "fg=colour8"

    """
}
