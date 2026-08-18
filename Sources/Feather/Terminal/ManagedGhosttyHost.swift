import AppKit
import GhosttyKit

enum ManagedGhosttyHostError: LocalizedError {
  case initializationFailed
  case configurationFailed
  case configurationDiagnostics(String)
  case appCreationFailed

  var errorDescription: String? {
    switch self {
    case .initializationFailed:
      "libghostty could not initialize."
    case .configurationFailed:
      "Feather could not create its terminal configuration."
    case .configurationDiagnostics(let message):
      "Feather's terminal configuration is invalid:\n\(message)"
    case .appCreationFailed:
      "libghostty could not create its renderer."
    }
  }
}

/// A narrow libghostty host that loads one explicit, app-owned configuration.
/// GhosttyKit's default host intentionally loads Ghostty's user files, which is
/// useful for terminal apps but contrary to Feather's fixed two-theme contract.
@MainActor
final class ManagedGhosttyHost: GhosttyTerminalHostProtocol {
  nonisolated(unsafe) private(set) var app: ghostty_app_t?
  nonisolated(unsafe) private(set) var config: ghostty_config_t?
  private(set) var configDiagnostics: [GhosttyTerminalConfigDiagnostic] = []

  private let configURL: URL
  private var sessions: [ObjectIdentifier: WeakManagedGhosttySession] = [:]
  nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

  init(configURL: URL) throws {
    self.configURL = configURL
    guard ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == 0 else {
      throw ManagedGhosttyHostError.initializationFailed
    }
    guard let config = Self.loadConfig(at: configURL) else {
      throw ManagedGhosttyHostError.configurationFailed
    }

    let diagnostics = Self.collectDiagnostics(from: config)
    guard diagnostics.isEmpty else {
      ghostty_config_free(config)
      throw ManagedGhosttyHostError.configurationDiagnostics(
        diagnostics.map(\.message).joined(separator: "\n")
      )
    }

    var runtime = ghostty_runtime_config_s(
      userdata: Unmanaged.passUnretained(self).toOpaque(),
      supports_selection_clipboard: false,
      wakeup_cb: featherGhosttyWakeup,
      action_cb: featherGhosttyAction,
      read_clipboard_cb: featherGhosttyReadClipboard,
      confirm_read_clipboard_cb: featherGhosttyConfirmReadClipboard,
      write_clipboard_cb: featherGhosttyWriteClipboard,
      close_surface_cb: featherGhosttyCloseSurface
    )
    guard let app = ghostty_app_new(&runtime, config) else {
      ghostty_config_free(config)
      throw ManagedGhosttyHostError.appCreationFailed
    }

    self.config = config
    self.app = app
    beginObservingApplicationFocus()
  }

  func setLaunchCommand(_ command: String) throws {
    let launchURL = configURL.deletingLastPathComponent().appendingPathComponent("launch")
    let launchText = "command = \(command)\n"
    if (try? String(contentsOf: launchURL, encoding: .utf8)) != launchText {
      try launchText.write(to: launchURL, atomically: true, encoding: .utf8)
    }
    guard let launchConfig = Self.loadConfig(at: configURL, overrideURL: launchURL) else {
      throw ManagedGhosttyHostError.configurationFailed
    }
    defer { ghostty_config_free(launchConfig) }
    let diagnostics = Self.collectDiagnostics(from: launchConfig)
    guard diagnostics.isEmpty else {
      throw ManagedGhosttyHostError.configurationDiagnostics(
        diagnostics.map(\.message).joined(separator: "\n")
      )
    }
    if let app {
      ghostty_app_update_config(app, launchConfig)
    }
  }

  deinit {
    disposeResources()
  }

  func dispose() {
    sessions.removeAll()
    disposeResources()
  }

  nonisolated private func disposeResources() {
    for observer in observers {
      NotificationCenter.default.removeObserver(observer)
    }
    observers.removeAll()
    if let app {
      self.app = nil
      ghostty_app_free(app)
    }
    if let config {
      self.config = nil
      ghostty_config_free(config)
    }
  }

  func register(_ session: GhosttyTerminalSession) {
    sessions[ObjectIdentifier(session)] = WeakManagedGhosttySession(value: session)
  }

  func unregister(_ session: GhosttyTerminalSession) {
    sessions.removeValue(forKey: ObjectIdentifier(session))
  }

  func tick() {
    guard let app else { return }
    ghostty_app_tick(app)
  }

  func setColorScheme(_ colorScheme: GhosttyTerminalColorScheme, appearance: NSAppearance? = nil) {
    guard let app, let scheme = managedGhosttyColorScheme(colorScheme, appearance: appearance)
    else { return }
    ghostty_app_set_color_scheme(app, scheme)
    for session in liveSessions() {
      session.applyColorScheme(colorScheme, appearance: appearance)
    }
  }

  func reloadConfig() {
    guard let newConfig = Self.loadConfig(at: configURL) else { return }
    let diagnostics = Self.collectDiagnostics(from: newConfig)
    guard diagnostics.isEmpty else {
      configDiagnostics = diagnostics
      ghostty_config_free(newConfig)
      return
    }

    let oldConfig = config
    config = newConfig
    configDiagnostics = []
    if let app {
      ghostty_app_update_config(app, newConfig)
    }
    for session in liveSessions() {
      session.updateConfig(newConfig)
    }
    if let oldConfig {
      ghostty_config_free(oldConfig)
    }
  }

  /// Configuration is intentionally controlled through Feather's settings.
  func openConfig() {}

  @discardableResult
  fileprivate func handle(action: GhosttyTerminalAction) -> Bool {
    switch action {
    case .render:
      for session in liveSessions() {
        session.requestRender()
      }
      return true
    case .reloadConfig:
      reloadConfig()
      return true
    case .ringBell:
      NSSound.beep()
      return true
    case .openConfig:
      return true
    default:
      return false
    }
  }

  private func liveSessions() -> [GhosttyTerminalSession] {
    sessions = sessions.filter { $0.value.value != nil }
    return sessions.values.compactMap(\.value)
  }

  private func beginObservingApplicationFocus() {
    let notificationCenter = NotificationCenter.default
    observers.append(
      notificationCenter.addObserver(
        forName: NSApplication.didBecomeActiveNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor [weak self] in self?.setAppFocused(true) }
      }
    )
    observers.append(
      notificationCenter.addObserver(
        forName: NSApplication.didResignActiveNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor [weak self] in self?.setAppFocused(false) }
      }
    )
    setAppFocused(NSApp?.isActive == true)
  }

  private func setAppFocused(_ focused: Bool) {
    guard let app else { return }
    ghostty_app_set_focus(app, focused)
  }

  private static func loadConfig(at url: URL, overrideURL: URL? = nil) -> ghostty_config_t? {
    guard let config = ghostty_config_new() else { return nil }
    url.path.withCString { ghostty_config_load_file(config, $0) }
    if let overrideURL {
      overrideURL.path.withCString { ghostty_config_load_file(config, $0) }
    }
    ghostty_config_load_recursive_files(config)
    ghostty_config_finalize(config)
    return config
  }

  private static func collectDiagnostics(
    from config: ghostty_config_t?
  ) -> [GhosttyTerminalConfigDiagnostic] {
    guard let config else { return [] }
    return (0..<ghostty_config_diagnostics_count(config)).compactMap { index in
      let diagnostic = ghostty_config_get_diagnostic(config, index)
      guard let message = diagnostic.message else { return nil }
      return GhosttyTerminalConfigDiagnostic(message: String(cString: message))
    }
  }
}

private struct WeakManagedGhosttySession {
  weak var value: GhosttyTerminalSession?
}

@MainActor
private func managedGhosttyColorScheme(
  _ colorScheme: GhosttyTerminalColorScheme,
  appearance: NSAppearance?
) -> ghostty_color_scheme_e? {
  switch colorScheme {
  case .light:
    GHOSTTY_COLOR_SCHEME_LIGHT
  case .dark:
    GHOSTTY_COLOR_SCHEME_DARK
  case .system:
    (appearance ?? NSApp?.effectiveAppearance ?? NSAppearance(named: .aqua))?
      .bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
      ? GHOSTTY_COLOR_SCHEME_DARK
      : GHOSTTY_COLOR_SCHEME_LIGHT
  }
}

private func featherGhosttyWakeup(_ userdata: UnsafeMutableRawPointer?) {
  guard let host = managedGhosttyHost(from: userdata) else { return }
  Task { @MainActor in host.tick() }
}

private func featherGhosttyAction(
  _ app: ghostty_app_t?,
  _ target: ghostty_target_s,
  _ action: ghostty_action_s
) -> Bool {
  guard let app, let host = managedGhosttyHost(from: ghostty_app_userdata(app)) else {
    return false
  }
  let terminalAction = managedGhosttyAction(from: action)
  Task { @MainActor in
    switch target.tag {
    case GHOSTTY_TARGET_SURFACE:
      if let session = managedGhosttySession(for: target.target.surface) {
        _ = session.handle(action: terminalAction)
      }
    case GHOSTTY_TARGET_APP:
      _ = host.handle(action: terminalAction)
    default:
      host.tick()
    }
  }
  return true
}

private func featherGhosttyReadClipboard(
  _ userdata: UnsafeMutableRawPointer?,
  _ location: ghostty_clipboard_e,
  _ state: UnsafeMutableRawPointer?
) -> Bool {
  guard location != GHOSTTY_CLIPBOARD_SELECTION else { return false }
  guard let session = managedGhosttySession(from: userdata), let surface = session.surface else {
    return false
  }
  guard let text = NSPasteboard.general.string(forType: .string) else { return false }
  text.withCString { ghostty_surface_complete_clipboard_request(surface, $0, state, false) }
  return true
}

private func featherGhosttyConfirmReadClipboard(
  _ userdata: UnsafeMutableRawPointer?,
  _ string: UnsafePointer<CChar>?,
  _ state: UnsafeMutableRawPointer?,
  _ request: ghostty_clipboard_request_e
) {}

private func featherGhosttyWriteClipboard(
  _ userdata: UnsafeMutableRawPointer?,
  _ location: ghostty_clipboard_e,
  _ content: UnsafePointer<ghostty_clipboard_content_s>?,
  _ length: Int,
  _ confirm: Bool
) {
  guard location != GHOSTTY_CLIPBOARD_SELECTION, let content, length > 0 else { return }
  let value = UnsafeBufferPointer(start: content, count: length).compactMap { item -> String? in
    guard
      let mime = item.mime,
      String(cString: mime) == "text/plain",
      let data = item.data
    else { return nil }
    return String(cString: data)
  }.joined(separator: "\n")
  guard !value.isEmpty else { return }
  NSPasteboard.general.clearContents()
  NSPasteboard.general.setString(value, forType: .string)
}

private func featherGhosttyCloseSurface(
  _ userdata: UnsafeMutableRawPointer?,
  _ processAlive: Bool
) {
  guard let session = managedGhosttySession(from: userdata) else { return }
  Task { @MainActor in session.closeHandler?(processAlive) }
}

private func managedGhosttyHost(from pointer: UnsafeMutableRawPointer?) -> ManagedGhosttyHost? {
  guard let pointer else { return nil }
  return Unmanaged<ManagedGhosttyHost>.fromOpaque(pointer).takeUnretainedValue()
}

private func managedGhosttySession(for surface: ghostty_surface_t?) -> GhosttyTerminalSession? {
  guard let surface, let userdata = ghostty_surface_userdata(surface) else { return nil }
  return managedGhosttySession(from: userdata)
}

private func managedGhosttySession(from pointer: UnsafeMutableRawPointer?)
  -> GhosttyTerminalSession?
{
  guard let pointer else { return nil }
  return Unmanaged<GhosttyTerminalSession>.fromOpaque(pointer).takeUnretainedValue()
}

private func managedGhosttyAction(from action: ghostty_action_s) -> GhosttyTerminalAction {
  switch action.tag {
  case GHOSTTY_ACTION_SET_TITLE:
    .setTitle(managedString(from: action.action.set_title.title))
  case GHOSTTY_ACTION_SET_TAB_TITLE:
    .setTabTitle(managedString(from: action.action.set_tab_title.title))
  case GHOSTTY_ACTION_PWD:
    .workingDirectory(managedString(from: action.action.pwd.pwd))
  case GHOSTTY_ACTION_MOUSE_OVER_LINK:
    .hoveredLink(
      managedString(
        from: action.action.mouse_over_link.url,
        length: Int(action.action.mouse_over_link.len)
      ))
  case GHOSTTY_ACTION_OPEN_URL:
    .openURL(
      managedString(
        from: action.action.open_url.url,
        length: Int(action.action.open_url.len)
      ))
  case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
    .desktopNotification(
      title: managedString(from: action.action.desktop_notification.title) ?? "Feather",
      body: managedString(from: action.action.desktop_notification.body) ?? ""
    )
  case GHOSTTY_ACTION_RENDERER_HEALTH:
    .rendererHealth(action.action.renderer_health == GHOSTTY_RENDERER_HEALTH_HEALTHY)
  case GHOSTTY_ACTION_READONLY:
    .readonly(action.action.readonly == GHOSTTY_READONLY_ON)
  case GHOSTTY_ACTION_RENDER:
    .render
  case GHOSTTY_ACTION_OPEN_CONFIG:
    .openConfig
  case GHOSTTY_ACTION_RELOAD_CONFIG:
    .reloadConfig
  case GHOSTTY_ACTION_RING_BELL:
    .ringBell
  case GHOSTTY_ACTION_START_SEARCH:
    .startSearch(managedString(from: action.action.start_search.needle) ?? "")
  case GHOSTTY_ACTION_END_SEARCH:
    .endSearch
  case GHOSTTY_ACTION_SEARCH_TOTAL:
    .searchTotal(Int(action.action.search_total.total))
  case GHOSTTY_ACTION_SEARCH_SELECTED:
    .searchSelected(
      action.action.search_selected.selected >= 0
        ? Int(action.action.search_selected.selected)
        : nil
    )
  case GHOSTTY_ACTION_PROGRESS_REPORT:
    .progress(
      state: managedProgressState(action.action.progress_report.state),
      percent: action.action.progress_report.progress >= 0
        ? Int(action.action.progress_report.progress)
        : nil
    )
  case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
    .childExited(exitCode: Int(action.action.child_exited.exit_code))
  case GHOSTTY_ACTION_COMMAND_FINISHED:
    .commandFinished(
      exitCode: action.action.command_finished.exit_code >= 0
        ? Int(action.action.command_finished.exit_code)
        : nil,
      durationNanoseconds: action.action.command_finished.duration
    )
  case GHOSTTY_ACTION_SECURE_INPUT:
    managedSecureInputAction(action.action.secure_input)
  case GHOSTTY_ACTION_NEW_WINDOW:
    .request(.newWindow)
  case GHOSTTY_ACTION_CLOSE_WINDOW:
    .request(.closeWindow)
  case GHOSTTY_ACTION_NEW_TAB:
    .request(.newTab)
  case GHOSTTY_ACTION_CLOSE_TAB:
    .request(.closeTab)
  case GHOSTTY_ACTION_NEW_SPLIT:
    .request(.newSplit(managedSplitDirection(action.action.new_split)))
  case GHOSTTY_ACTION_EQUALIZE_SPLITS:
    .request(.equalizeSplits)
  case GHOSTTY_ACTION_TOGGLE_SPLIT_ZOOM:
    .request(.toggleSplitZoom)
  case GHOSTTY_ACTION_TOGGLE_COMMAND_PALETTE:
    .request(.toggleCommandPalette)
  case GHOSTTY_ACTION_SIZE_LIMIT:
    .sizeLimit(
      .init(
        minimumWidth: Int(action.action.size_limit.min_width),
        minimumHeight: Int(action.action.size_limit.min_height),
        maximumWidth: action.action.size_limit.max_width > 0
          ? Int(action.action.size_limit.max_width)
          : nil,
        maximumHeight: action.action.size_limit.max_height > 0
          ? Int(action.action.size_limit.max_height)
          : nil
      ))
  case GHOSTTY_ACTION_INITIAL_SIZE:
    .initialSize(
      .init(
        width: Int(action.action.initial_size.width),
        height: Int(action.action.initial_size.height)
      ))
  case GHOSTTY_ACTION_CELL_SIZE:
    .cellSize(
      .init(
        width: Int(action.action.cell_size.width),
        height: Int(action.action.cell_size.height)
      ))
  case GHOSTTY_ACTION_COPY_TITLE_TO_CLIPBOARD:
    .copyTitleToClipboard
  case GHOSTTY_ACTION_MOUSE_SHAPE:
    .mouseShape(action.action.mouse_shape)
  case GHOSTTY_ACTION_MOUSE_VISIBILITY:
    .mouseVisibility(hidden: action.action.mouse_visibility == GHOSTTY_MOUSE_HIDDEN)
  default:
    .unsupported("unknown")
  }
}

private func managedProgressState(
  _ state: ghostty_action_progress_report_state_e
) -> GhosttyTerminalProgressState {
  switch state {
  case GHOSTTY_PROGRESS_STATE_SET: .active
  case GHOSTTY_PROGRESS_STATE_ERROR: .error
  case GHOSTTY_PROGRESS_STATE_INDETERMINATE: .indeterminate
  case GHOSTTY_PROGRESS_STATE_PAUSE: .paused
  default: .none
  }
}

private func managedSecureInputAction(
  _ state: ghostty_action_secure_input_e
) -> GhosttyTerminalAction {
  switch state {
  case GHOSTTY_SECURE_INPUT_ON: .secureInput(.active)
  case GHOSTTY_SECURE_INPUT_OFF: .secureInput(.inactive)
  case GHOSTTY_SECURE_INPUT_TOGGLE: .unsupported("secure_input_toggle")
  default: .unsupported("secure_input")
  }
}

private func managedSplitDirection(
  _ direction: ghostty_action_split_direction_e
) -> GhosttyTerminalSplitDirection {
  switch direction {
  case GHOSTTY_SPLIT_DIRECTION_LEFT: .left
  case GHOSTTY_SPLIT_DIRECTION_UP: .up
  case GHOSTTY_SPLIT_DIRECTION_DOWN: .down
  default: .right
  }
}

private func managedString(from pointer: UnsafePointer<CChar>?) -> String? {
  pointer.map(String.init(cString:))
}

private func managedString(from pointer: UnsafePointer<CChar>?, length: Int) -> String? {
  guard let pointer, length > 0 else { return nil }
  return String(
    decoding: UnsafeBufferPointer(start: pointer, count: length).map(UInt8.init(bitPattern:)),
    as: UTF8.self
  )
}
