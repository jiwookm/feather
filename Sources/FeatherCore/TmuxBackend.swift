import Darwin
import Foundation

public struct TmuxLaunchSpec: Equatable, Sendable {
  static let stateChangeChannel = "feather-state-change"
  public let executableURL: URL
  public let configURL: URL
  public let socketName: String

  public init(executableURL: URL, configURL: URL, socketName: String) {
    self.executableURL = executableURL
    self.configURL = configURL
    self.socketName = socketName
  }

  public func attachCommand(sessionID: String, workingDirectory: String) -> String {
    [
      executableURL.path,
      "-L", socketName,
      "-f", configURL.path,
      "new-session", "-A",
      "-s", sessionID,
      "-c", workingDirectory,
    ]
    .map(Self.shellQuote)
    .joined(separator: " ")
  }

  var signalStateChangeCommand: String {
    [
      executableURL.path,
      "-L", socketName,
      "-f", configURL.path,
      "wait-for", "-S", Self.stateChangeChannel,
    ]
    .map(Self.shellQuote)
    .joined(separator: " ")
  }

  func markAttentionCommand(sessionID: String) -> String {
    let mark = [
      executableURL.path,
      "-L", socketName,
      "-f", configURL.path,
      "set-option", "-w", "-t", sessionID, "@feather-attention", "1",
    ]
    .map(Self.shellQuote)
    .joined(separator: " ")
    return "\(mark); \(signalStateChangeCommand)"
  }

  private static func shellQuote(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
  }
}

public enum TmuxEnvironment {
  public static func prepare(
    applicationSupportURL: URL,
    // This identifier intentionally survives the product rename so live sessions reattach.
    socketName: String = "barnacle-\(getuid())",
    fileManager: FileManager = .default
  ) throws -> TmuxLaunchSpec {
    guard let executable = locateExecutable(fileManager: fileManager) else {
      throw FeatherError.tmuxUnavailable
    }
    try fileManager.createDirectory(at: applicationSupportURL, withIntermediateDirectories: true)
    let configURL = applicationSupportURL.appendingPathComponent("tmux.conf")
    let config = """
      # Managed by Feather. Personal tmux configuration is intentionally not loaded.
      set-environment -gu NO_COLOR
      set -g default-shell /bin/zsh
      set -g default-command "/usr/bin/env -u NO_COLOR /bin/zsh -l"
      set -g default-terminal "tmux-256color"
      set -as terminal-features ",xterm-ghostty:RGB:focus:title:clipboard"
      set -g focus-events on
      set -g mouse on
      set-window-option -g monitor-bell on
      set -g status off
      set -g history-limit 10000
      set -g set-clipboard on
      set -g allow-passthrough on
      set -g detach-on-destroy on
      set -g pane-border-style "fg=colour8"
      set -g pane-active-border-style "fg=colour8"
      set-hook -g alert-bell 'wait-for -S feather-state-change'
      set-hook -g pane-exited 'wait-for -S feather-state-change'
      """
    if (try? String(contentsOf: configURL, encoding: .utf8)) != config {
      try config.write(to: configURL, atomically: true, encoding: .utf8)
    }
    _ = try? CommandRunner().run(
      executable.path,
      arguments: [
        "-L", socketName,
        "set-option", "-g", "mouse", "on", ";",
        "set-option", "-g", "pane-border-style", "fg=colour8", ";",
        "set-option", "-g", "pane-active-border-style", "fg=colour8",
        ";", "set-window-option", "-g", "monitor-bell", "on",
        ";", "set-hook", "-g", "alert-bell", "wait-for -S feather-state-change",
        ";", "set-hook", "-g", "pane-exited", "wait-for -S feather-state-change",
      ],
      allowFailure: true
    )
    _ = try? CommandRunner().run(
      executable.path,
      arguments: ["-L", socketName, "set-environment", "-gu", "NO_COLOR"],
      allowFailure: true
    )
    return TmuxLaunchSpec(executableURL: executable, configURL: configURL, socketName: socketName)
  }

  public static func locateExecutable(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    fileManager: FileManager = .default
  ) -> URL? {
    let pathCandidates = (environment["PATH"] ?? "")
      .split(separator: ":")
      .map { URL(fileURLWithPath: String($0)).appendingPathComponent("tmux") }
    let fixedCandidates = [
      URL(fileURLWithPath: "/opt/homebrew/bin/tmux"),
      URL(fileURLWithPath: "/usr/local/bin/tmux"),
      URL(fileURLWithPath: "/usr/bin/tmux"),
    ]
    return (fixedCandidates + pathCandidates).first {
      fileManager.isExecutableFile(atPath: $0.path)
    }
  }
}

public actor TmuxBackend: TerminalBackend {
  private let spec: TmuxLaunchSpec
  private let runner: CommandRunner
  private let eventRunner: BoundedCommandRunner

  public init(
    spec: TmuxLaunchSpec,
    runner: CommandRunner = CommandRunner(),
    eventRunner: BoundedCommandRunner = BoundedCommandRunner()
  ) {
    self.spec = spec
    self.runner = runner
    self.eventRunner = eventRunner
  }

  public func sessionExists(_ sessionID: String) async throws -> Bool {
    let result = try run(["has-session", "-t", sessionID], allowFailure: true)
    return result.status == 0
  }

  public func ensureSession(_ sessionID: String, workingDirectory: String) async throws {
    guard try await sessionExists(sessionID) == false else { return }
    _ = try run([
      "set-environment", "-gu", "NO_COLOR", ";",
      "new-session", "-d", "-s", sessionID,
      "-c", workingDirectory,
    ])
  }

  public func foregroundCommand(_ sessionID: String) async throws -> String? {
    try await activePane(sessionID)?.command
  }

  public func activePane(_ sessionID: String) async throws -> TerminalPaneState? {
    let result = try run(
      [
        "display-message", "-p", "-t", sessionID,
        "#{pane_id}\t#{pane_current_command}\t#{window_panes}",
      ],
      allowFailure: true
    )
    guard result.status == 0 else { return nil }
    let fields = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
      .split(separator: "\t", omittingEmptySubsequences: false)
    guard fields.count == 3, let totalCount = Int(fields[2]) else { return nil }
    return TerminalPaneState(
      id: String(fields[0]),
      command: fields[1].isEmpty ? "terminal process" : String(fields[1]),
      totalCount: totalCount
    )
  }

  public func launchCommand(
    _ command: String,
    sessionID: String,
    workingDirectory: String
  ) throws {
    _ = try run([
      "set-environment", "-gu", "NO_COLOR", ";",
      "new-session", "-d", "-s", sessionID,
      "-c", workingDirectory,
      "--", "/usr/bin/env", "-u", "NO_COLOR", "/bin/zsh", "-lic",
      "\(command); \(spec.markAttentionCommand(sessionID: sessionID)); "
        + "exec /usr/bin/env -u NO_COLOR /bin/zsh -l",
    ])
  }

  public func splitPane(
    sessionID: String,
    workingDirectory: String,
    direction: TerminalSplitDirection
  ) async throws {
    try await ensureSession(sessionID, workingDirectory: workingDirectory)
    let splitFlag = direction == .right ? "-h" : "-v"
    _ = try run([
      "split-window", splitFlag,
      "-t", sessionID,
      "-c", workingDirectory,
    ])
  }

  public func killPane(_ paneID: String, sessionID: String) async throws -> Bool {
    let panes = try run(
      ["list-panes", "-t", sessionID, "-F", "#{pane_id}"],
      allowFailure: true
    )
    guard panes.status == 0 else { return false }
    let paneIDs = panes.text.split(whereSeparator: \.isNewline).map(String.init)
    guard paneIDs.count > 1, paneIDs.contains(paneID) else { return false }
    _ = try run(["kill-pane", "-t", paneID])
    return true
  }

  public func killSession(_ sessionID: String) async throws {
    guard try await sessionExists(sessionID) else { return }
    _ = try run(["kill-session", "-t", sessionID])
  }

  public func killServer() async throws {
    let arguments = ["kill-server"]
    let result = try run(arguments, allowFailure: true)
    guard result.status == 0 || result.status == 1 else {
      throw CommandFailure(
        executable: spec.executableURL.path,
        arguments: ["-L", spec.socketName, "-f", spec.configURL.path] + arguments,
        status: result.status,
        output: result.text
      )
    }
  }

  public func runtimeSnapshots() throws -> [TmuxSessionRuntimeSnapshot] {
    let result = try run(
      [
        "list-panes", "-a", "-f", "#{pane_active}", "-F",
        "#{session_name}\t#{pane_current_command}\t#{pane_dead}\t#{window_bell_flag}\t#{@feather-attention}",
      ],
      allowFailure: true
    )
    guard result.status == 0 else { return [] }
    return TmuxSessionRuntimeParser.parse(result.text)
  }

  public func acknowledgeAttention(sessionID: String) throws {
    _ = try run(
      ["set-option", "-w", "-u", "-t", sessionID, "@feather-attention"],
      allowFailure: true
    )
    _ = try run(["kill-session", "-C", "-t", sessionID], allowFailure: true)
  }

  public func waitForStateChange() async throws {
    let output = try await eventRunner.run(
      spec.executableURL.path,
      arguments: [
        "-L", spec.socketName, "-f", spec.configURL.path,
        "wait-for", TmuxLaunchSpec.stateChangeChannel,
      ],
      maximumOutputBytes: 64 * 1_024,
      timeout: 7 * 24 * 60 * 60
    )
    guard output.status == 0 else {
      throw BoundedCommandFailure(
        executable: spec.executableURL.path,
        arguments: ["wait-for", TmuxLaunchSpec.stateChangeChannel],
        status: output.status,
        stderr: output.stderrText
      )
    }
  }

  private func run(_ arguments: [String], allowFailure: Bool = false) throws -> CommandOutput {
    try runner.run(
      spec.executableURL.path,
      arguments: ["-L", spec.socketName, "-f", spec.configURL.path] + arguments,
      allowFailure: allowFailure
    )
  }
}

enum TmuxSessionRuntimeParser {
  static func parse(_ text: String) -> [TmuxSessionRuntimeSnapshot] {
    text.split(whereSeparator: \.isNewline).compactMap { line in
      let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
      guard fields.count >= 4 else { return nil }
      return TmuxSessionRuntimeSnapshot(
        sessionID: String(fields[0]),
        command: String(fields[1]),
        paneDead: fields[2] == "1",
        hasBell: fields[3] == "1" || (fields.count >= 5 && fields[4] == "1")
      )
    }
  }
}
