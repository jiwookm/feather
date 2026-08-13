import Foundation
import Testing

@testable import FeatherCore

struct TmuxBackendTests {
  @Test
  func managesAnIsolatedSession() async throws {
    guard let tmux = TmuxEnvironment.locateExecutable() else {
      return
    }

    let fileManager = FileManager.default
    let temporaryRoot = fileManager.temporaryDirectory
      .appendingPathComponent("feather-tmux-\(UUID().uuidString)", isDirectory: true)
    defer { try? fileManager.removeItem(at: temporaryRoot) }
    let socketName = "feather-test-\(UUID().uuidString.lowercased())"
    let runner = CommandRunner()
    defer {
      _ = try? runner.run(
        tmux.path,
        arguments: ["-L", socketName, "kill-server"],
        allowFailure: true
      )
    }
    try runner.run(
      tmux.path,
      arguments: ["-L", socketName, "-f", "/dev/null", "new-session", "-d", "-s", "existing"]
    )
    try runner.run(
      tmux.path,
      arguments: ["-L", socketName, "set-environment", "-g", "NO_COLOR", "1"]
    )

    let spec = try TmuxEnvironment.prepare(
      applicationSupportURL: temporaryRoot,
      socketName: socketName
    )
    let config = try String(contentsOf: spec.configURL, encoding: .utf8)
    #expect(config.contains("set -g pane-border-style \"fg=colour8\""))
    #expect(config.contains("set -g pane-active-border-style \"fg=colour8\""))
    #expect(config.contains("set -g mouse on"))
    let liveMouse = try runner.run(
      tmux.path,
      arguments: ["-L", socketName, "show-options", "-gv", "mouse"]
    ).text.trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(liveMouse == "on")
    let liveBorderStyle = try runner.run(
      tmux.path,
      arguments: ["-L", socketName, "show-options", "-gv", "pane-active-border-style"]
    ).text.trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(liveBorderStyle == "fg=colour8")
    let backend = TmuxBackend(spec: spec)
    let sessionID = "session"

    let colorEnvironment = try runner.run(
      tmux.path,
      arguments: ["-L", socketName, "show-environment", "-g", "NO_COLOR"],
      allowFailure: true
    )
    #expect(colorEnvironment.status != 0)
    let attachCommand = spec.attachCommand(
      sessionID: sessionID,
      workingDirectory: temporaryRoot.path
    )
    #expect(attachCommand.hasPrefix("'\(tmux.path)'"))
    #expect(attachCommand.contains("'\(sessionID)'"))
    try await backend.ensureSession(sessionID, workingDirectory: temporaryRoot.path)
    #expect(try await backend.sessionExists(sessionID))
    let initialPane = try #require(try await backend.activePane(sessionID))
    try runner.run(
      tmux.path,
      arguments: ["-L", socketName, "respawn-pane", "-k", "-t", initialPane.id, "/bin/cat"]
    )

    try await backend.splitPane(
      sessionID: sessionID,
      workingDirectory: temporaryRoot.path,
      direction: .right
    )
    let rightPane = try #require(try await backend.activePane(sessionID))
    try runner.run(
      tmux.path,
      arguments: ["-L", socketName, "respawn-pane", "-k", "-t", rightPane.id, "/bin/cat"]
    )
    try await backend.splitPane(
      sessionID: sessionID,
      workingDirectory: temporaryRoot.path,
      direction: .down
    )
    let downPane = try #require(try await backend.activePane(sessionID))
    try runner.run(
      tmux.path,
      arguments: ["-L", socketName, "respawn-pane", "-k", "-t", downPane.id, "/bin/cat"]
    )
    let panePaths = try runner.run(
      tmux.path,
      arguments: ["-L", socketName, "list-panes", "-t", sessionID, "-F", "#{pane_current_path}"]
    ).text.split(whereSeparator: \.isNewline).map(String.init)
    #expect(panePaths.count == 3)
    #expect(Set(panePaths).count == 1)
    #expect(panePaths.first?.hasSuffix(temporaryRoot.path) == true)

    let newestPane = try #require(try await backend.activePane(sessionID))
    #expect(newestPane.totalCount == 3)
    #expect(try await backend.killPane(newestPane.id, sessionID: sessionID))
    let secondPane = try #require(try await backend.activePane(sessionID))
    #expect(secondPane.totalCount == 2)
    #expect(try await backend.killPane(secondPane.id, sessionID: sessionID))
    let finalPane = try #require(try await backend.activePane(sessionID))
    #expect(finalPane.totalCount == 1)
    #expect(!(try await backend.killPane(finalPane.id, sessionID: sessionID)))
    #expect(try await backend.sessionExists(sessionID))

    let markerURL = temporaryRoot.appendingPathComponent("agent-launched")
    try await backend.launchCommand(
      "if [[ -z ${NO_COLOR+x} ]]; then /usr/bin/touch \(markerURL.path); fi",
      sessionID: "agent-session",
      workingDirectory: temporaryRoot.path
    )
    for _ in 0..<100 where !fileManager.fileExists(atPath: markerURL.path) {
      try await Task.sleep(for: .milliseconds(50))
    }
    #expect(fileManager.fileExists(atPath: markerURL.path))

    try await backend.killSession(sessionID)
    #expect(!(try await backend.sessionExists(sessionID)))
  }
}
