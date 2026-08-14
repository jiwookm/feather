import FeatherCore
import Foundation
import GhosttyKit
import Testing

@testable import Feather

struct TerminalConfigurationTests {
  @Test
  func terminalLaunchesUseTheRequestedAgentModesWithoutMonochromeInheritance() {
    #expect(
      TerminalLaunch.claude.command
        == "/usr/bin/env -u NO_COLOR claude --dangerously-skip-permissions"
    )
    #expect(
      TerminalLaunch.codex.command
        == "/usr/bin/env -u NO_COLOR codex '--dangerously-bypass-approvals-and-sandbox'"
    )
    #expect(TerminalLaunch.terminal.command == nil)
  }

  @Test
  func identifiesOnlyAgentTerminalsForSidebarBadges() {
    let repositoryID = UUID()
    let makeTerminal = { (title: String) in
      TerminalRecord(
        repositoryID: repositoryID,
        worktreePath: "/tmp/worktree",
        title: title,
        order: 0
      )
    }

    #expect(AgentKind(terminal: makeTerminal("Claude")) == .claude)
    #expect(AgentKind(terminal: makeTerminal("Codex")) == .codex)
    #expect(AgentKind(terminal: makeTerminal("Terminal 1")) == nil)
  }

  @Test
  func showsRuntimeBadgesOnlyForStatesThatNeedAttention() {
    #expect(!TerminalRuntimeState.shell.showsNotificationBadge)
    #expect(!TerminalRuntimeState.running.showsNotificationBadge)
    #expect(TerminalRuntimeState.attention.showsNotificationBadge)
    #expect(TerminalRuntimeState.exited.showsNotificationBadge)
  }

  @Test @MainActor
  func managedConfigurationIsValidAndFixed() throws {
    let fileManager = FileManager.default
    let temporaryRoot = fileManager.temporaryDirectory
      .appendingPathComponent("Feather Config \(UUID().uuidString)", isDirectory: true)
    defer { try? fileManager.removeItem(at: temporaryRoot) }

    let configURL = try FeatherGhosttyConfiguration.write(to: temporaryRoot)
    let configText = try String(contentsOf: configURL, encoding: .utf8)
    let darkText = try String(
      contentsOf: configURL.deletingLastPathComponent().appendingPathComponent("feather-dark"),
      encoding: .utf8
    )
    let lightText = try String(
      contentsOf: configURL.deletingLastPathComponent().appendingPathComponent("feather-light"),
      encoding: .utf8
    )

    #expect(configText.contains("font-family = JetBrains Mono"))
    #expect(configText.contains("font-size = 14"))
    #expect(configText.contains("window-padding-x = 4"))
    #expect(configText.contains("window-padding-y = 4"))
    #expect(configText.contains("cursor-style = bar"))
    #expect(configText.contains("cursor-style-blink = true"))
    #expect(configText.contains("mouse-hide-while-typing = false"))
    #expect(configText.contains("background-opacity = 1"))
    #expect(configText.contains("keybind = super+w=unbind"))
    #expect(configText.contains("keybind = super+d=unbind"))
    #expect(configText.contains("keybind = super+shift+d=unbind"))
    #expect(configText.contains("keybind = super+,=unbind"))
    #expect(darkText.contains("background = 0d0d0d"))
    #expect(darkText.contains("foreground = d6deeb"))
    #expect(darkText.contains("palette = 4=#82aaff"))
    #expect(lightText.contains("background = f7f7f7"))
    #expect(lightText.contains("minimum-contrast = 4.5"))
    #expect(lightText.contains("palette = 231=#242424"))
    #expect(lightText.contains("palette = 237=#ededed"))
    #expect(!darkText.contains("minimum-contrast"))

    let host = try ManagedGhosttyHost(configURL: configURL)
    let config = try #require(host.config)
    #expect(host.configDiagnostics.isEmpty)
    var opacity = 0.0
    let key = "background-opacity"
    let found = key.withCString { ghostty_config_get(config, &opacity, $0, UInt(key.utf8.count)) }
    #expect(found)
    #expect(opacity == 1)
    var minimumContrast = 0.0
    let contrastKey = "minimum-contrast"
    let foundContrast = contrastKey.withCString {
      ghostty_config_get(config, &minimumContrast, $0, UInt(contrastKey.utf8.count))
    }
    #expect(foundContrast)
    #expect(minimumContrast == 4.5)
  }

  @Test @MainActor
  func ghosttyKeepsTheNewSurfaceAttachedWhenSwitchingTerminals() async throws {
    guard let tmux = TmuxEnvironment.locateExecutable() else { return }

    let fileManager = FileManager.default
    let temporaryRoot = fileManager.temporaryDirectory
      .appendingPathComponent("Feather Attach \(UUID().uuidString)", isDirectory: true)
    defer { try? fileManager.removeItem(at: temporaryRoot) }
    let socketName = "feather-surface-test-\(UUID().uuidString.lowercased())"
    let runner = CommandRunner()
    defer {
      _ = try? runner.run(
        tmux.path,
        arguments: ["-L", socketName, "kill-server"],
        allowFailure: true
      )
    }

    let spec = try TmuxEnvironment.prepare(
      applicationSupportURL: temporaryRoot,
      socketName: socketName
    )
    let backend = TmuxBackend(spec: spec)
    let repositoryID = UUID()
    let first = TerminalRecord(
      repositoryID: repositoryID,
      worktreePath: temporaryRoot.path,
      title: "Claude",
      order: 0,
      tmuxSessionID: "claude"
    )
    let second = TerminalRecord(
      repositoryID: repositoryID,
      worktreePath: temporaryRoot.path,
      title: "Codex",
      order: 1,
      tmuxSessionID: "codex"
    )
    try await backend.ensureSession(first.tmuxSessionID, workingDirectory: temporaryRoot.path)
    try await backend.ensureSession(second.tmuxSessionID, workingDirectory: temporaryRoot.path)

    let registry = TerminalRegistry(applicationSupportURL: temporaryRoot, launchSpec: spec)
    var firstHandle = registry.handle(for: first, appearance: .dark)
    #expect(firstHandle != nil)
    firstHandle?.view.frame.size = CGSize(width: 640, height: 480)
    let firstSurface = try #require(firstHandle?.session.surface)
    ghostty_surface_set_size(firstSurface, 1, 1)
    firstHandle?.view.handlers?.updateContentScale()
    let correctedSize = ghostty_surface_size(firstSurface)
    #expect(correctedSize.width_px > 1)
    #expect(correctedSize.height_px > 1)

    var clients = ""
    for _ in 0..<100 where !clients.contains(first.tmuxSessionID) {
      try await Task.sleep(for: .milliseconds(20))
      clients = try runner.run(
        tmux.path,
        arguments: ["-L", socketName, "list-clients", "-F", "#{client_session}"],
        allowFailure: true
      ).text
    }
    #expect(clients.contains(first.tmuxSessionID))

    let secondHandle = try #require(registry.handle(for: second, appearance: .dark))
    secondHandle.view.frame.size = CGSize(width: 640, height: 480)
    for _ in 0..<100 where !clients.contains(second.tmuxSessionID) {
      try await Task.sleep(for: .milliseconds(20))
      clients = try runner.run(
        tmux.path,
        arguments: ["-L", socketName, "list-clients", "-F", "#{client_session}"],
        allowFailure: true
      ).text
    }
    #expect(clients.contains(second.tmuxSessionID))

    registry.release(first.id)
    firstHandle = nil
    try await Task.sleep(for: .milliseconds(50))
    clients = try runner.run(
      tmux.path,
      arguments: ["-L", socketName, "list-clients", "-F", "#{client_session}"],
      allowFailure: true
    ).text
    #expect(clients.contains(second.tmuxSessionID))
    _ = secondHandle
  }
}
