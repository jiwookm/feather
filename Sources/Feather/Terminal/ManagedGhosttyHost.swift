import AppKit
import LibGhostty

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
@MainActor
final class ManagedGhosttyHost {
  nonisolated(unsafe) private(set) var app: ghostty_app_t?
  nonisolated(unsafe) private(set) var config: ghostty_config_t?
  private(set) var configDiagnostics: [FeatherGhosttyConfigDiagnostic] = []

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

  func register(_ session: FeatherGhosttySession) {
    sessions[ObjectIdentifier(session)] = WeakManagedGhosttySession(value: session)
  }

  func unregister(_ session: FeatherGhosttySession) {
    sessions.removeValue(forKey: ObjectIdentifier(session))
  }

  func tick() {
    guard let app else { return }
    ghostty_app_tick(app)
  }

  func setColorScheme(_ colorScheme: FeatherGhosttyColorScheme, appearance: NSAppearance? = nil) {
    guard let app, let scheme = resolveGhosttyColorScheme(colorScheme, appearance: appearance)
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
  fileprivate func handle(action: FeatherGhosttyAction) -> Bool {
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

  private func liveSessions() -> [FeatherGhosttySession] {
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
  ) -> [FeatherGhosttyConfigDiagnostic] {
    guard let config else { return [] }
    return (0..<ghostty_config_diagnostics_count(config)).compactMap { index in
      let diagnostic = ghostty_config_get_diagnostic(config, index)
      guard let message = diagnostic.message else { return nil }
      return FeatherGhosttyConfigDiagnostic(message: String(cString: message))
    }
  }
}

private struct WeakManagedGhosttySession {
  weak var value: FeatherGhosttySession?
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
  let targetSession =
    target.tag == GHOSTTY_TARGET_SURFACE
    ? managedGhosttySession(for: target.target.surface)
    : nil
  Task { @MainActor in
    switch target.tag {
    case GHOSTTY_TARGET_SURFACE:
      if let targetSession {
        _ = targetSession.handle(action: terminalAction)
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

private func managedGhosttySession(for surface: ghostty_surface_t?) -> FeatherGhosttySession? {
  guard let surface, let userdata = ghostty_surface_userdata(surface) else { return nil }
  return managedGhosttySession(from: userdata)
}

private func managedGhosttySession(from pointer: UnsafeMutableRawPointer?)
  -> FeatherGhosttySession?
{
  guard let pointer else { return nil }
  return Unmanaged<FeatherGhosttySession>.fromOpaque(pointer).takeUnretainedValue()
}

private func managedGhosttyAction(from action: ghostty_action_s) -> FeatherGhosttyAction {
  switch action.tag {
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
    .desktopNotification
  case GHOSTTY_ACTION_RENDER:
    .render
  case GHOSTTY_ACTION_OPEN_CONFIG:
    .openConfig
  case GHOSTTY_ACTION_RELOAD_CONFIG:
    .reloadConfig
  case GHOSTTY_ACTION_RING_BELL:
    .ringBell
  case GHOSTTY_ACTION_PROGRESS_REPORT:
    .progress(
      managedProgressState(action.action.progress_report.state),
      action.action.progress_report.progress >= 0
        ? Int(action.action.progress_report.progress)
        : nil
    )
  case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
    .childExited
  case GHOSTTY_ACTION_COMMAND_FINISHED:
    .commandFinished
  case GHOSTTY_ACTION_SECURE_INPUT:
    managedSecureInputAction(action.action.secure_input)
  case GHOSTTY_ACTION_CLOSE_WINDOW:
    .request(.closeWindow)
  case GHOSTTY_ACTION_NEW_TAB:
    .request(.newTab)
  case GHOSTTY_ACTION_CLOSE_TAB:
    .request(.closeTab)
  case GHOSTTY_ACTION_MOUSE_SHAPE:
    .mouseShape(action.action.mouse_shape)
  case GHOSTTY_ACTION_MOUSE_VISIBILITY:
    .mouseVisibility(action.action.mouse_visibility == GHOSTTY_MOUSE_HIDDEN)
  default:
    .unsupported
  }
}

private func managedProgressState(
  _ state: ghostty_action_progress_report_state_e
) -> FeatherGhosttyProgressState {
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
) -> FeatherGhosttyAction {
  switch state {
  case GHOSTTY_SECURE_INPUT_ON: .secureInput(true)
  case GHOSTTY_SECURE_INPUT_OFF: .secureInput(false)
  default: .unsupported
  }
}

private func managedString(from pointer: UnsafePointer<CChar>?, length: Int) -> String? {
  guard let pointer, length > 0 else { return nil }
  return String(
    decoding: UnsafeBufferPointer(start: pointer, count: length).map(UInt8.init(bitPattern:)),
    as: UTF8.self
  )
}
