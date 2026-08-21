import AppKit
import FeatherCore
import Foundation
import LibGhostty
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
    #expect(TerminalRuntimeState.offline.showsNotificationBadge)
  }

  @Test
  func polledAgentResponsesNotifyOnceUntilTheAgentWorksAgain() {
    let completed = PolledTerminalRuntimePolicy.decide(
      reportedState: .running,
      stateWithoutAttention: .running,
      agentActivity: .waiting,
      isSelected: false,
      responseAcknowledged: false
    )
    #expect(completed.state == .attention)
    #expect(completed.acknowledgement == .keep)

    let opened = PolledTerminalRuntimePolicy.decide(
      reportedState: .running,
      stateWithoutAttention: .running,
      agentActivity: .waiting,
      isSelected: true,
      responseAcknowledged: false
    )
    #expect(opened.state == .running)
    #expect(opened.acknowledgement == .record)

    let stillWaiting = PolledTerminalRuntimePolicy.decide(
      reportedState: .running,
      stateWithoutAttention: .running,
      agentActivity: .waiting,
      isSelected: false,
      responseAcknowledged: true
    )
    #expect(stillWaiting.state == .running)
    #expect(stillWaiting.acknowledgement == .keep)

    let workingAgain = PolledTerminalRuntimePolicy.decide(
      reportedState: .running,
      stateWithoutAttention: .running,
      agentActivity: .working,
      isSelected: false,
      responseAcknowledged: true
    )
    #expect(workingAgain.state == .running)
    #expect(workingAgain.acknowledgement == .clear)
  }

  @Test
  func scrollModifiersUseGhosttysPackedPrecisionAndMomentumLayout() {
    #expect(
      FeatherGhosttyScrollModifiers.encode(precision: false, momentumPhase: []) == 0
    )
    #expect(
      FeatherGhosttyScrollModifiers.encode(precision: true, momentumPhase: []) == 1
    )
    #expect(
      FeatherGhosttyScrollModifiers.encode(precision: true, momentumPhase: .stationary)
        == 1 | ghostty_input_scroll_mods_t(GHOSTTY_MOUSE_MOMENTUM_STATIONARY.rawValue) << 1
    )
    #expect(
      FeatherGhosttyScrollModifiers.encode(precision: true, momentumPhase: .changed)
        == 1 | ghostty_input_scroll_mods_t(GHOSTTY_MOUSE_MOMENTUM_CHANGED.rawValue) << 1
    )
    #expect(
      FeatherGhosttyScrollModifiers.encode(precision: false, momentumPhase: .mayBegin)
        == ghostty_input_scroll_mods_t(GHOSTTY_MOUSE_MOMENTUM_MAY_BEGIN.rawValue) << 1
    )
  }

  @Test
  func terminalLinksResolveWebURLsAndLocalFilePaths() {
    let workingDirectory = "/tmp/feather-worktree"

    #expect(
      FeatherGhosttyLinkTarget.resolve(
        "https://example.com/docs",
        workingDirectory: workingDirectory
      )
        == URL(string: "https://example.com/docs")
    )
    #expect(
      FeatherGhosttyLinkTarget.resolve("file:///tmp/abc.html", workingDirectory: workingDirectory)
        == URL(fileURLWithPath: "/tmp/abc.html")
    )
    #expect(
      FeatherGhosttyLinkTarget.resolve("/tmp/abc.html", workingDirectory: workingDirectory)
        == URL(fileURLWithPath: "/tmp/abc.html")
    )
    #expect(
      FeatherGhosttyLinkTarget.resolve("docs/index.html", workingDirectory: workingDirectory)
        == URL(fileURLWithPath: "/tmp/feather-worktree/docs/index.html")
    )
    #expect(
      FeatherGhosttyLinkTarget.resolve("~/notes.html", workingDirectory: workingDirectory)
        == URL(fileURLWithPath: NSString(string: "~/notes.html").expandingTildeInPath)
    )
    #expect(FeatherGhosttyLinkTarget.resolve("", workingDirectory: workingDirectory) == nil)
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
    #expect(configText.contains("mouse-scroll-multiplier = precision:0.525,discrete:3"))
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
  func repeatedTerminalSwitchesDisposeOldSurfacesAndClients() async throws {
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
    let terminals = [first, second]
    var retainedHandles: [TerminalHandle] = []

    for switchIndex in 0..<12 {
      let terminal = terminals[switchIndex % terminals.count]
      let handle = try #require(registry.handle(for: terminal, appearance: .dark))
      handle.view.frame.size = CGSize(width: 640, height: 480)
      retainedHandles.append(handle)

      if switchIndex == 0 {
        let surface = try #require(handle.session.surface)
        ghostty_surface_set_size(surface, 1, 1)
        handle.view.layer?.contentsScale = 99
        handle.view.viewDidChangeBackingProperties()
        let correctedSize = ghostty_surface_size(surface)
        #expect(correctedSize.width_px > 1)
        #expect(correctedSize.height_px > 1)
        let expectedScale =
          handle.view.window?.backingScaleFactor
          ?? NSScreen.main?.backingScaleFactor
          ?? 2
        #expect(handle.view.layer?.contentsScale == expectedScale)

        ghostty_surface_set_size(surface, 1, 1)
        handle.session.synchronizeGeometry()
        let screenChangeCorrectedSize = ghostty_surface_size(surface)
        #expect(screenChangeCorrectedSize.width_px > 1)
        #expect(screenChangeCorrectedSize.height_px > 1)
      }

      let attachedClients = try await waitForTmuxClients(
        [terminal.tmuxSessionID],
        executable: tmux.path,
        socketName: socketName,
        runner: runner
      )
      #expect(attachedClients == [terminal.tmuxSessionID])

      guard switchIndex < 11 else { continue }
      registry.release(terminal.id)
      handle.dispose()
      #expect(handle.isDisposed)
      #expect(handle.session.surface == nil)
      #expect(handle.view.session == nil)
      #expect(handle.host.app == nil)
      #expect(handle.host.config == nil)
      let detachedClients = try await waitForTmuxClients(
        [],
        executable: tmux.path,
        socketName: socketName,
        runner: runner
      )
      #expect(detachedClients.isEmpty)
    }

    #expect(retainedHandles.compactMap { $0.session.surface }.count == 1)
    #expect(retainedHandles.compactMap { $0.view.session }.count == 1)
    #expect(retainedHandles.compactMap { $0.host.app }.count == 1)
    #expect(try await backend.sessionExists(first.tmuxSessionID))
    #expect(try await backend.sessionExists(second.tmuxSessionID))

    registry.release(second.id)
    let detachedClients = try await waitForTmuxClients(
      [],
      executable: tmux.path,
      socketName: socketName,
      runner: runner
    )
    #expect(detachedClients.isEmpty)
  }

  private func waitForTmuxClients(
    _ expected: [String],
    executable: String,
    socketName: String,
    runner: CommandRunner
  ) async throws -> [String] {
    var clients: [String] = []
    for _ in 0..<100 {
      let output = try runner.run(
        executable,
        arguments: ["-L", socketName, "list-clients", "-F", "#{client_session}"],
        allowFailure: true
      )
      clients =
        output.status == 0
        ? output.text.split(whereSeparator: \.isNewline).map(String.init)
        : []
      if clients == expected { return clients }
      try await Task.sleep(for: .milliseconds(20))
    }
    return clients
  }
}
