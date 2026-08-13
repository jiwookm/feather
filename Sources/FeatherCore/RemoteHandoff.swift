import Foundation

enum RemoteHandoffError: LocalizedError, Equatable, Sendable {
  case invalidHost
  case invalidPort
  case invalidRootPath
  case invalidSession
  case dirtyWorktree(String)
  case detachedHead
  case missingOrigin
  case unpublishedCommit(String)

  var errorDescription: String? {
    switch self {
    case .invalidHost:
      "Enter an SSH host or alias using letters, numbers, `.`, `-`, `_`, `@`, `:`, or brackets."
    case .invalidPort:
      "The SSH port must be between 1 and 65535."
    case .invalidRootPath:
      "The remote root must be an absolute path below `/`, without `.` or `..` components."
    case .invalidSession:
      "This terminal has invalid session metadata. Recreate the terminal before handoff."
    case .dirtyWorktree(let path):
      "Remote handoff requires a clean worktree: \(path)"
    case .detachedHead:
      "Remote handoff requires a named Git branch."
    case .missingOrigin:
      "Remote handoff requires an `origin` remote."
    case .unpublishedCommit(let branch):
      "Push `\(branch)` first. Feather only hands off a commit that exactly matches `origin`."
    }
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

enum POSIXShell {
  static func quote(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
  }
}

public actor RemoteHandoffService {
  private let runner: BoundedCommandRunner
  private let gitExecutable: String
  private let sshExecutable: String

  public init(
    runner: BoundedCommandRunner = BoundedCommandRunner(),
    gitExecutable: String = "/usr/bin/git",
    sshExecutable: String = "/usr/bin/ssh"
  ) {
    self.runner = runner
    self.gitExecutable = gitExecutable
    self.sshExecutable = sshExecutable
  }

  public func prepare(
    repository: RepositoryRecord,
    worktreePath: String,
    terminalID: UUID,
    sessionID: String,
    target: SSHRemoteTarget
  ) async throws -> SSHRemoteTerminal {
    let target = try SSHRemoteTargetValidator.validate(target)
    let sessionID = try SSHRemoteTargetValidator.validateSessionID(sessionID)
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

    let suffix = terminalID.uuidString.lowercased().prefix(8)
    let repositoryName = Self.slug(repository.displayName)
    let worktreeName = Self.slug(URL(fileURLWithPath: worktreePath).lastPathComponent)
    let destination = "\(target.rootPath)/worktrees/\(repositoryName)-\(worktreeName)-\(suffix)"
    let controlRoot = "\(target.rootPath)/.feather"
    let configPath = "\(controlRoot)/tmux.conf"
    let summaryPath = "\(controlRoot)/handoffs/\(sessionID).txt"
    let summary = Self.handoffSummary(
      repository: repository.displayName,
      branch: branch,
      commit: commit,
      workingDirectory: destination
    )
    let script = Self.preparationScript(
      origin: origin,
      branch: branch,
      commit: commit,
      destination: destination,
      controlRoot: controlRoot,
      configPath: configPath,
      summaryPath: summaryPath,
      summary: summary,
      sessionID: sessionID
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
        arguments: [target.host, "prepare Feather handoff"],
        status: remote.status,
        stderr: remote.stderrText
      )
    }

    return SSHRemoteTerminal(
      target: target,
      workingDirectory: destination,
      tmuxConfigPath: configPath
    )
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
    summaryPath: String,
    summary: String,
    sessionID: String
  ) -> String {
    let parent = (destination as NSString).deletingLastPathComponent
    let handoffDirectory = (summaryPath as NSString).deletingLastPathComponent
    let terminalCommand =
      "cat -- \(POSIXShell.quote(summaryPath)); rm -f -- \(POSIXShell.quote(summaryPath)); "
      + "exec \"${SHELL:-/bin/sh}\" -l"
    return """
      set -eu
      destination=\(POSIXShell.quote(destination))
      summary=\(POSIXShell.quote(summaryPath))
      session=\(POSIXShell.quote(sessionID))
      cleanup=1
      destination_created=0
      session_created=0
      cleanup_handoff() {
        status=$?
        trap - EXIT HUP INT TERM
        if [ "$cleanup" -eq 1 ] && [ "$session_created" -eq 1 ]; then
          tmux -L feather -f \(POSIXShell.quote(configPath)) kill-session -t "$session" >/dev/null 2>&1 || true
        fi
        if [ "$cleanup" -eq 1 ] && [ "$destination_created" -eq 1 ]; then
          rm -rf -- "$destination"
        fi
        if [ "$cleanup" -eq 1 ]; then
          rm -f -- "$summary"
        fi
        exit "$status"
      }
      trap cleanup_handoff EXIT HUP INT TERM
      command -v git >/dev/null
      command -v tmux >/dev/null
      command -v base64 >/dev/null
      test ! -e "$destination"
      ! tmux -L feather -f \(POSIXShell.quote(configPath)) has-session -t "$session" >/dev/null 2>&1
      mkdir -p -- \(POSIXShell.quote(parent)) \(POSIXShell.quote(controlRoot)) \(POSIXShell.quote(handoffDirectory))
      printf %s \(POSIXShell.quote(Data(remoteTmuxConfiguration.utf8).base64EncodedString())) | base64 -d > \(POSIXShell.quote(configPath))
      destination_created=1
      git clone --no-checkout --single-branch --branch \(POSIXShell.quote(branch)) -- \(POSIXShell.quote(origin)) "$destination"
      git -C "$destination" checkout -B \(POSIXShell.quote(branch)) \(POSIXShell.quote(commit))
      test -z "$(git -C "$destination" status --porcelain=v1 --untracked-files=all)"
      printf %s \(POSIXShell.quote(Data(summary.utf8).base64EncodedString())) | base64 -d > "$summary"
      session_created=1
      tmux -L feather -f \(POSIXShell.quote(configPath)) new-session -d -s "$session" -c "$destination" -- /bin/sh -lc \(POSIXShell.quote(terminalCommand))
      cleanup=0
      trap - EXIT HUP INT TERM
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

  private static func handoffSummary(
    repository: String,
    branch: String,
    commit: String,
    workingDirectory: String
  ) -> String {
    """

    Feather remote handoff is ready.
    Repository: \(repository)
    Branch: \(branch)
    Commit: \(commit)
    Working directory: \(workingDirectory)

    The local worktree was clean and this commit matched origin when Feather prepared the host.
    Start Claude Code or Codex here. Resume a provider session only if its session data is available on this host.

    """
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
