import AppKit
import FeatherCore
import Foundation

extension Notification.Name {
  static let featherNewTerminalRequested = Notification.Name("FeatherNewTerminalRequested")
  static let featherCloseTerminalRequested = Notification.Name("FeatherCloseTerminalRequested")
  static let featherCloseContextRequested = Notification.Name("FeatherCloseContextRequested")
  static let featherToggleSidebarRequested = Notification.Name("FeatherToggleSidebarRequested")
  static let featherToggleInspectorRequested = Notification.Name(
    "FeatherToggleInspectorRequested")
  static let featherSaveDocumentRequested = Notification.Name("FeatherSaveDocumentRequested")
  static let featherQuickOpenRequested = Notification.Name("FeatherQuickOpenRequested")
  static let featherRepositorySearchRequested = Notification.Name(
    "FeatherRepositorySearchRequested")
  static let featherWorkspaceShortcutRequested = Notification.Name(
    "FeatherWorkspaceShortcutRequested")
}

@MainActor
final class TerminalHandle {
  let host: ManagedGhosttyHost
  let session: FeatherGhosttySession
  let view: FeatherGhosttyView
  private(set) var isDisposed = false

  init(host: ManagedGhosttyHost, session: FeatherGhosttySession, view: FeatherGhosttyView) {
    self.host = host
    self.session = session
    self.view = view
  }

  func dispose() {
    guard !isDisposed else { return }
    isDisposed = true
    session.dispose()
    host.dispose()
  }
}

enum TerminalSurfaceRuntimeEvent: Equatable {
  case running
  case attention
  case commandFinished
  case exited
}

@MainActor
final class TerminalRegistry {
  private let configURL: URL?
  private let launchSpec: TmuxLaunchSpec?
  private var idleHost: ManagedGhosttyHost?
  private var handles: [UUID: TerminalHandle] = [:]
  private(set) var initializationError: String?
  var runtimeEventHandler: ((UUID, TerminalSurfaceRuntimeEvent) -> Void)?

  init(applicationSupportURL: URL, launchSpec: TmuxLaunchSpec?) {
    self.launchSpec = launchSpec
    do {
      let configURL = try FeatherGhosttyConfiguration.write(to: applicationSupportURL)
      let host = try ManagedGhosttyHost(configURL: configURL)
      self.configURL = configURL
      idleHost = host
    } catch {
      configURL = nil
      idleHost = nil
      initializationError = error.localizedDescription
    }
  }

  func handle(
    for terminal: TerminalRecord,
    executionTarget: TerminalExecutionTarget? = nil,
    appearance: AppearancePreference
  ) -> TerminalHandle? {
    if let existing = handles[terminal.id] { return existing }
    guard let configURL else { return nil }

    let attachCommand: String
    switch executionTarget ?? terminal.executionTarget {
    case .local:
      guard let launchSpec else { return nil }
      attachCommand = launchSpec.attachCommand(
        sessionID: terminal.tmuxSessionID,
        workingDirectory: terminal.worktreePath
      )
    case .ssh(let remote):
      attachCommand = remote.attachCommand(sessionID: terminal.tmuxSessionID)
    }

    let host: ManagedGhosttyHost
    do {
      if let availableHost = idleHost {
        host = availableHost
        idleHost = nil
      } else {
        host = try ManagedGhosttyHost(configURL: configURL)
      }
      try host.setLaunchCommand(attachCommand)
    } catch {
      initializationError = error.localizedDescription
      return nil
    }
    let session = FeatherGhosttySession(
      host: host,
      workingDirectory: terminal.worktreePath,
      colorScheme: appearance.ghosttyColorScheme
    )
    session.closeHandler = { processAlive in
      NotificationCenter.default.post(
        name: .featherCloseTerminalRequested,
        object: nil,
        userInfo: [
          "terminalID": terminal.id,
          "requiresConfirmation": processAlive,
        ]
      )
    }
    session.requestHandler = { request in
      switch request {
      case .newTab:
        NotificationCenter.default.post(name: .featherNewTerminalRequested, object: nil)
      case .closeTab, .closeWindow:
        NotificationCenter.default.post(
          name: .featherCloseTerminalRequested,
          object: nil,
          userInfo: ["terminalID": terminal.id]
        )
      }
    }
    session.actionHandler = { [weak self] action in
      let event: TerminalSurfaceRuntimeEvent?
      switch action {
      case .desktopNotification, .ringBell:
        event = .attention
      case .progress(let state, _):
        switch state {
        case .active, .indeterminate:
          event = .running
        case .error, .none, .paused:
          event = nil
        }
      case .commandFinished:
        event = .commandFinished
      case .childExited:
        event = .exited
      default:
        event = nil
      }
      if let event {
        self?.runtimeEventHandler?(terminal.id, event)
      }
    }
    let view = session.makeView()
    view.layer?.backgroundColor =
      NSColor(hex: appearance.usesLightSurface ? 0xF7F7F7 : 0x0D0D0D)
      .cgColor
    let handle = TerminalHandle(host: host, session: session, view: view)
    handles[terminal.id] = handle
    return handle
  }

  /// Inactive surfaces are discarded; tmux retains the process and canonical terminal state.
  /// This keeps Feather at one live Metal surface per visible terminal workspace.
  func release(_ terminalID: UUID) {
    guard let handle = handles.removeValue(forKey: terminalID) else { return }
    handle.dispose()
  }

  func updateAppearance(_ appearance: AppearancePreference) {
    idleHost?.setColorScheme(appearance.ghosttyColorScheme)
    for handle in handles.values {
      handle.host.setColorScheme(appearance.ghosttyColorScheme)
    }
  }
}

extension AppearancePreference {
  fileprivate var ghosttyColorScheme: FeatherGhosttyColorScheme {
    switch self {
    case .system: .system
    case .light: .light
    case .dark: .dark
    }
  }

  @MainActor fileprivate var usesLightSurface: Bool {
    switch self {
    case .light:
      true
    case .dark:
      false
    case .system:
      NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) != .darkAqua
    }
  }
}

enum FeatherGhosttyConfiguration {
  static func write(to applicationSupportURL: URL, fileManager: FileManager = .default) throws
    -> URL
  {
    let directory = applicationSupportURL.appendingPathComponent("GhosttyConfig", isDirectory: true)
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

    let lightURL = directory.appendingPathComponent("feather-light")
    let darkURL = directory.appendingPathComponent("feather-dark")
    let configURL = directory.appendingPathComponent("config")

    let light = """
      background = f7f7f7
      foreground = 242424
      minimum-contrast = 4.5
      cursor-color = 242424
      cursor-text = ffffff
      selection-background = d9e8ff
      selection-foreground = 242424
      palette = 0=#242424
      palette = 1=#c5221f
      palette = 2=#3b7d23
      palette = 3=#9a6700
      palette = 4=#0969da
      palette = 5=#8250df
      palette = 6=#1b7c83
      palette = 7=#d8d8d8
      palette = 8=#6e7781
      palette = 9=#d1242f
      palette = 10=#4c8c2b
      palette = 11=#bf8700
      palette = 12=#218bff
      palette = 13=#a475f9
      palette = 14=#3192aa
      palette = 15=#ffffff
      palette = 231=#242424
      palette = 237=#ededed
      """
    let dark = """
      background = 0d0d0d
      foreground = d6deeb
      cursor-color = 7e57c2
      cursor-text = ffffff
      selection-background = 5f7e97
      selection-foreground = dfe5ee
      palette = 0=#011627
      palette = 1=#ef5350
      palette = 2=#22da6e
      palette = 3=#addb67
      palette = 4=#82aaff
      palette = 5=#c792ea
      palette = 6=#21c7a8
      palette = 7=#ffffff
      palette = 8=#575656
      palette = 9=#ef5350
      palette = 10=#22da6e
      palette = 11=#ffeb95
      palette = 12=#82aaff
      palette = 13=#c792ea
      palette = 14=#7fdbca
      palette = 15=#ffffff
      """
    let config = """
      # Managed by Feather. The app intentionally exposes only these two palettes.
      theme = "light:\(escaped(lightURL.path)),dark:\(escaped(darkURL.path))"
      font-family = JetBrains Mono
      font-size = 14
      background-opacity = 1
      window-padding-x = 4
      window-padding-y = 4
      cursor-style = bar
      cursor-style-blink = true
      cursor-opacity = 1
      mouse-hide-while-typing = false
      mouse-scroll-multiplier = precision:0.525,discrete:3
      copy-on-select = false
      shell-integration = none
      keybind = super+,=unbind
      keybind = super+shift+,=unbind
      keybind = ctrl+tab=unbind
      keybind = ctrl+shift+tab=unbind
      keybind = super+d=unbind
      keybind = super+shift+d=unbind
      keybind = super+w=unbind
      """

    try write(light, to: lightURL)
    try write(dark, to: darkURL)
    try write(config, to: configURL)
    return configURL
  }

  private static func write(_ content: String, to url: URL) throws {
    if (try? String(contentsOf: url, encoding: .utf8)) != content {
      try content.write(to: url, atomically: true, encoding: .utf8)
    }
  }

  private static func escaped(_ path: String) -> String {
    path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
  }
}
