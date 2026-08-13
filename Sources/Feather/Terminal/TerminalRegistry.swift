import AppKit
import FeatherCore
import Foundation
import GhosttyKit

extension Notification.Name {
  static let featherNewTerminalRequested = Notification.Name("FeatherNewTerminalRequested")
  static let featherCloseTerminalRequested = Notification.Name("FeatherCloseTerminalRequested")
  static let featherCloseContextRequested = Notification.Name("FeatherCloseContextRequested")
  static let featherToggleSidebarRequested = Notification.Name("FeatherToggleSidebarRequested")
  static let featherToggleInspectorRequested = Notification.Name(
    "FeatherToggleInspectorRequested")
  static let featherSaveDocumentRequested = Notification.Name("FeatherSaveDocumentRequested")
  static let featherQuickOpenRequested = Notification.Name("FeatherQuickOpenRequested")
}

@MainActor
struct TerminalHandle {
  let host: ManagedGhosttyHost
  let session: GhosttyTerminalSession
  let view: GhosttyTerminalView
}

@MainActor
final class TerminalRegistry {
  private let configURL: URL?
  private let launchSpec: TmuxLaunchSpec?
  private var idleHost: ManagedGhosttyHost?
  private var handles: [UUID: TerminalHandle] = [:]
  private(set) var initializationError: String?

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

  func handle(for terminal: TerminalRecord, appearance: AppearancePreference) -> TerminalHandle? {
    if let existing = handles[terminal.id] { return existing }
    guard let configURL, let launchSpec else { return nil }

    let host: ManagedGhosttyHost
    do {
      if let availableHost = idleHost {
        host = availableHost
        idleHost = nil
      } else {
        host = try ManagedGhosttyHost(configURL: configURL)
      }
      try host.setLaunchCommand(
        launchSpec.attachCommand(
          sessionID: terminal.tmuxSessionID,
          workingDirectory: terminal.worktreePath
        )
      )
    } catch {
      initializationError = error.localizedDescription
      return nil
    }
    let launch = GhosttyTerminalLaunchConfiguration(
      workingDirectory: terminal.worktreePath,
      colorScheme: appearance.ghosttyColorScheme
    )
    let session = GhosttyTerminalSession(host: host, configuration: launch)
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
      default:
        break
      }
    }
    let view = session.makeView()
    if var handlers = view.handlers {
      let updateContentScale = handlers.updateContentScale
      handlers.updateContentScale = { [weak session, weak view] in
        updateContentScale()
        guard let session, let view else { return }
        session.resize(to: view.bounds.size)
      }
      view.handlers = handlers
    }
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
    handles.removeValue(forKey: terminalID)
  }

  func updateAppearance(_ appearance: AppearancePreference) {
    idleHost?.setColorScheme(appearance.ghosttyColorScheme)
    for handle in handles.values {
      handle.host.setColorScheme(appearance.ghosttyColorScheme)
    }
  }
}

extension AppearancePreference {
  fileprivate var ghosttyColorScheme: GhosttyTerminalColorScheme {
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
