import Foundation

public actor SSHTmuxBackend: TerminalBackend {
  private let remote: SSHRemoteTerminal
  private let runner: BoundedCommandRunner
  private let sshExecutable: String

  public init(
    remote: SSHRemoteTerminal,
    runner: BoundedCommandRunner = BoundedCommandRunner(),
    sshExecutable: String = "/usr/bin/ssh"
  ) {
    self.remote = remote
    self.runner = runner
    self.sshExecutable = sshExecutable
  }

  public func sessionExists(_ sessionID: String) async throws -> Bool {
    let result = try await run(["has-session", "-t", sessionID], allowFailure: true)
    if result.status == 0 { return true }
    if result.status == 1 { return false }
    throw failure(result)
  }

  public func ensureSession(_ sessionID: String, workingDirectory: String) async throws {
    guard try await sessionExists(sessionID) == false else { return }
    _ = try await run([
      "new-session", "-d", "-s", sessionID,
      "-c", remote.workingDirectory,
    ])
  }

  public func launchCommand(
    _ command: String,
    sessionID: String,
    workingDirectory: String
  ) async throws {
    guard try await sessionExists(sessionID) == false else { return }
    _ = try await run(Self.launchArguments(command, sessionID: sessionID, remote: remote))
  }

  public func foregroundCommand(_ sessionID: String) async throws -> String? {
    try await activePane(sessionID)?.command
  }

  public func activePane(_ sessionID: String) async throws -> TerminalPaneState? {
    let result = try await run(
      [
        "display-message", "-p", "-t", sessionID,
        "#{pane_id}\t#{pane_current_command}\t#{window_panes}",
      ],
      allowFailure: true
    )
    if result.status == 1 { return nil }
    guard result.status == 0 else { throw failure(result) }
    let fields = result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
      .split(separator: "\t", omittingEmptySubsequences: false)
    guard fields.count == 3, let totalCount = Int(fields[2]) else { return nil }
    return TerminalPaneState(
      id: String(fields[0]),
      command: fields[1].isEmpty ? "remote process" : String(fields[1]),
      totalCount: totalCount
    )
  }

  public func splitPane(
    sessionID: String,
    workingDirectory: String,
    direction: TerminalSplitDirection
  ) async throws {
    try await ensureSession(sessionID, workingDirectory: remote.workingDirectory)
    _ = try await run([
      "split-window", direction == .right ? "-h" : "-v",
      "-t", sessionID,
      "-c", remote.workingDirectory,
    ])
  }

  public func killPane(_ paneID: String, sessionID: String) async throws -> Bool {
    let panes = try await run(
      ["list-panes", "-t", sessionID, "-F", "#{pane_id}"],
      allowFailure: true
    )
    if panes.status == 1 { return false }
    guard panes.status == 0 else { throw failure(panes) }
    let paneIDs = panes.stdoutText.split(whereSeparator: \.isNewline).map(String.init)
    guard paneIDs.count > 1, paneIDs.contains(paneID) else { return false }
    _ = try await run(["kill-pane", "-t", paneID])
    return true
  }

  public func killSession(_ sessionID: String) async throws {
    guard try await sessionExists(sessionID) else { return }
    _ = try await run(["kill-session", "-t", sessionID])
  }

  public func killServer() async throws {
    let result = try await run(["kill-server"], allowFailure: true)
    guard result.status == 0 || result.status == 1 else { throw failure(result) }
  }

  public func runtimeSnapshots() async throws -> [TmuxSessionRuntimeSnapshot] {
    let result = try await run(
      [
        "list-panes", "-a", "-f", "#{pane_active}", "-F",
        "#{session_name}\t#{pane_current_command}\t#{pane_dead}\t#{window_bell_flag}\t#{@feather-attention}\t#{pane_title}",
      ],
      allowFailure: true
    )
    if result.status == 1 { return [] }
    guard result.status == 0 else { throw failure(result) }
    return TmuxSessionRuntimeParser.parse(result.stdoutText)
  }

  public func acknowledgeAttention(sessionID: String) async throws {
    let unset = try await run(
      ["set-option", "-w", "-u", "-t", sessionID, "@feather-attention"],
      allowFailure: true
    )
    guard unset.status == 0 || unset.status == 1 else { throw failure(unset) }
    let clearBell = try await run(
      ["kill-session", "-C", "-t", sessionID],
      allowFailure: true
    )
    guard clearBell.status == 0 || clearBell.status == 1 else { throw failure(clearBell) }
  }

  private func run(
    _ arguments: [String],
    allowFailure: Bool = false
  ) async throws -> BoundedCommandOutput {
    let command = Self.tmuxCommand(remote: remote, arguments: arguments)
    let output = try await runner.run(
      sshExecutable,
      arguments: [
        "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-o", "ForwardAgent=no", "-p",
        String(remote.target.port), "--", remote.target.host, command,
      ],
      maximumOutputBytes: 256 * 1_024,
      timeout: 20
    )
    if !allowFailure, output.status != 0 {
      throw failure(output)
    }
    return output
  }

  static func tmuxCommand(remote: SSHRemoteTerminal, arguments: [String]) -> String {
    ([
      "tmux", "-L", remote.tmuxSocketName, "-f", remote.tmuxConfigPath,
    ] + arguments).map(POSIXShell.quote).joined(separator: " ")
  }

  static func launchArguments(
    _ command: String,
    sessionID: String,
    remote: SSHRemoteTerminal
  ) -> [String] {
    let markAttention = tmuxCommand(
      remote: remote,
      arguments: ["set-option", "-w", "-t", sessionID, "@feather-attention", "1"]
    )
    let shellCommand =
      "\(command); \(markAttention); printf '\\a'; exec \"${SHELL:-/bin/sh}\" -l"
    return [
      "new-session", "-d", "-s", sessionID,
      "-c", remote.workingDirectory,
      "--", "/usr/bin/env", "-u", "NO_COLOR", "/bin/sh", "-lc", shellCommand,
    ]
  }

  private func failure(_ output: BoundedCommandOutput) -> BoundedCommandFailure {
    BoundedCommandFailure(
      executable: sshExecutable,
      arguments: [remote.target.host, "tmux"],
      status: output.status,
      stderr: output.stderrText
    )
  }
}

extension SSHRemoteTerminal {
  public func attachCommand(sessionID: String) -> String {
    let remoteCommand = [
      "tmux", "-L", tmuxSocketName, "-f", tmuxConfigPath,
      "attach-session", "-t", sessionID,
    ]
    .map(POSIXShell.quote)
    .joined(separator: " ")
    return [
      "/usr/bin/ssh", "-tt", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
      "-o", "ForwardAgent=no", "-p", String(target.port), "--", target.host, remoteCommand,
    ]
    .map(POSIXShell.quote)
    .joined(separator: " ")
  }
}
