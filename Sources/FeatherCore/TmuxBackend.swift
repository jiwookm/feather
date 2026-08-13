import Darwin
import Foundation

public struct TmuxLaunchSpec: Equatable, Sendable {
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
      set -g status off
      set -g history-limit 10000
      set -g set-clipboard on
      set -g allow-passthrough on
      set -g detach-on-destroy on
      set -g pane-border-style "fg=colour8"
      set -g pane-active-border-style "fg=colour8"
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
  public let spec: TmuxLaunchSpec
  private let runner: CommandRunner

  public init(spec: TmuxLaunchSpec, runner: CommandRunner = CommandRunner()) {
    self.spec = spec
    self.runner = runner
  }

  public func sessionExists(_ sessionID: String) throws -> Bool {
    let result = try run(["has-session", "-t", sessionID], allowFailure: true)
    return result.status == 0
  }

  public func ensureSession(_ sessionID: String, workingDirectory: String) throws {
    guard try !sessionExists(sessionID) else { return }
    _ = try run([
      "set-environment", "-gu", "NO_COLOR", ";",
      "new-session", "-d", "-s", sessionID,
      "-c", workingDirectory,
    ])
  }

  public func foregroundCommand(_ sessionID: String) throws -> String? {
    try activePane(sessionID)?.command
  }

  public func activePane(_ sessionID: String) throws -> TerminalPaneState? {
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
      "\(command); exec /usr/bin/env -u NO_COLOR /bin/zsh -l",
    ])
  }

  public func splitPane(
    sessionID: String,
    workingDirectory: String,
    direction: TerminalSplitDirection
  ) throws {
    try ensureSession(sessionID, workingDirectory: workingDirectory)
    let splitFlag = direction == .right ? "-h" : "-v"
    _ = try run([
      "split-window", splitFlag,
      "-t", sessionID,
      "-c", workingDirectory,
    ])
  }

  public func killPane(_ paneID: String, sessionID: String) throws -> Bool {
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

  public func killSession(_ sessionID: String) throws {
    _ = try run(["kill-session", "-t", sessionID], allowFailure: true)
  }

  private func run(_ arguments: [String], allowFailure: Bool = false) throws -> CommandOutput {
    try runner.run(
      spec.executableURL.path,
      arguments: ["-L", spec.socketName, "-f", spec.configURL.path] + arguments,
      allowFailure: allowFailure
    )
  }
}
