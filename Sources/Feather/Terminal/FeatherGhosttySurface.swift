import AppKit
import Carbon
import LibGhostty
import QuartzCore

enum FeatherGhosttyColorScheme: Sendable {
  case light
  case dark
  case system
}

enum FeatherGhosttyProgressState {
  case none
  case active
  case error
  case indeterminate
  case paused
}

enum FeatherGhosttyRequest {
  case newTab
  case closeTab
  case closeWindow
}

enum FeatherGhosttyAction {
  case hoveredLink(String?)
  case openURL(String?)
  case desktopNotification
  case render
  case openConfig
  case reloadConfig
  case ringBell
  case progress(FeatherGhosttyProgressState, Int?)
  case childExited
  case commandFinished
  case secureInput(Bool)
  case request(FeatherGhosttyRequest)
  case mouseShape(ghostty_action_mouse_shape_e)
  case mouseVisibility(Bool)
  case unsupported
}

struct FeatherGhosttyConfigDiagnostic {
  let message: String
}

@MainActor
final class FeatherGhosttySession {
  let host: ManagedGhosttyHost
  nonisolated(unsafe) private(set) var surface: ghostty_surface_t?
  private(set) weak var view: FeatherGhosttyView?
  var closeHandler: ((Bool) -> Void)?
  var actionHandler: ((FeatherGhosttyAction) -> Void)?
  var requestHandler: ((FeatherGhosttyRequest) -> Void)?

  private let workingDirectory: String
  private var colorScheme: FeatherGhosttyColorScheme
  nonisolated(unsafe) private var secureEventInputEnabled = false
  private var hoveredLinkURL: String?
  private var isDisposed = false

  init(
    host: ManagedGhosttyHost,
    workingDirectory: String,
    colorScheme: FeatherGhosttyColorScheme
  ) {
    self.host = host
    self.workingDirectory = workingDirectory
    self.colorScheme = colorScheme
    host.register(self)
  }

  deinit {
    if secureEventInputEnabled {
      DisableSecureEventInput()
    }
    if let surface {
      ghostty_surface_free(surface)
    }
  }

  func makeView() -> FeatherGhosttyView {
    let view = FeatherGhosttyView()
    view.attach(session: self)
    self.view = view
    createSurface(in: view)
    synchronizeGeometry()
    applyColorScheme(colorScheme, appearance: view.effectiveAppearance)
    return view
  }

  func dispose() {
    guard !isDisposed else { return }
    isDisposed = true

    view?.detach()
    view = nil
    closeHandler = nil
    actionHandler = nil
    requestHandler = nil
    hoveredLinkURL = nil

    if secureEventInputEnabled {
      DisableSecureEventInput()
      secureEventInputEnabled = false
    }
    if let surface {
      self.surface = nil
      ghostty_surface_free(surface)
    }
    host.unregister(self)
  }

  func synchronizeGeometry() {
    guard let view else { return }
    let scale =
      view.window?.backingScaleFactor
      ?? view.window?.screen?.backingScaleFactor
      ?? NSScreen.main?.backingScaleFactor
      ?? 2
    guard scale.isFinite, scale > 0 else { return }

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    view.layer?.contentsScale = scale
    CATransaction.commit()

    updateContentScale(scale)
    resize(to: view.bounds.size, scale: scale)
    setDisplayID(view.currentDisplayID)
    requestRender()
  }

  func resize(to size: CGSize) {
    let scale =
      view?.window?.backingScaleFactor
      ?? view?.window?.screen?.backingScaleFactor
      ?? NSScreen.main?.backingScaleFactor
      ?? 2
    resize(to: size, scale: scale)
  }

  func render() {
    guard let surface else { return }
    ghostty_surface_draw(surface)
  }

  func requestRender() {
    view?.requestRender()
  }

  func setFocused(_ focused: Bool) {
    guard let surface else { return }
    ghostty_surface_set_focus(surface, focused)
  }

  func setOccluded(_ occluded: Bool) {
    guard let surface else { return }
    ghostty_surface_set_occlusion(surface, !occluded)
    if !occluded { requestRender() }
  }

  func keyboardLayoutChanged() {
    guard let app = host.app else { return }
    ghostty_app_keyboard_changed(app)
  }

  func sendKeyDown(_ event: NSEvent, text: String?) {
    sendKeyEvent(
      event,
      action: event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS,
      text: text
    )
    ghostty_surface_refresh(surface)
  }

  func sendKeyUp(_ event: NSEvent) {
    sendKeyEvent(event, action: GHOSTTY_ACTION_RELEASE, text: nil)
    ghostty_surface_refresh(surface)
  }

  func insertText(_ text: String) {
    guard let surface, !text.isEmpty else { return }
    text.withCString { ghostty_surface_text(surface, $0, UInt(text.utf8.count)) }
    ghostty_surface_refresh(surface)
  }

  func setMarkedText(_ text: String?) {
    guard let surface else { return }
    if let text {
      text.withCString { ghostty_surface_preedit(surface, $0, UInt(text.utf8.count)) }
    } else {
      ghostty_surface_preedit(surface, nil, 0)
    }
    ghostty_surface_refresh(surface)
  }

  func sendMouseButton(_ button: FeatherGhosttyMouseButton, pressed: Bool, event: NSEvent)
    -> Bool
  {
    guard let surface else { return false }
    let state: ghostty_input_mouse_state_e = pressed ? GHOSTTY_MOUSE_PRESS : GHOSTTY_MOUSE_RELEASE
    return ghostty_surface_mouse_button(
      surface,
      state,
      translate(button),
      translateModifiers(event.modifierFlags)
    )
  }

  func sendMousePosition(_ event: NSEvent) {
    guard let surface, let view else { return }
    let position = view.convert(event.locationInWindow, from: nil)
    ghostty_surface_mouse_pos(
      surface,
      position.x,
      view.bounds.height - position.y,
      translateModifiers(event.modifierFlags)
    )
  }

  func sendMouseExit(modifiers: NSEvent.ModifierFlags) {
    guard let surface else { return }
    ghostty_surface_mouse_pos(surface, -1, -1, translateModifiers(modifiers))
  }

  func sendScrollWheel(_ event: NSEvent) {
    guard let surface else { return }
    ghostty_surface_mouse_scroll(
      surface,
      event.scrollingDeltaX,
      event.scrollingDeltaY,
      translateScrollModifiers(event)
    )
  }

  func copySelection() -> String? {
    guard let surface else { return nil }
    var text = ghostty_text_s()
    guard ghostty_surface_read_selection(surface, &text) else { return nil }
    defer { ghostty_surface_free_text(surface, &text) }
    return String(cString: text.text)
  }

  func hasSelection() -> Bool {
    guard let surface else { return false }
    return ghostty_surface_has_selection(surface)
  }

  func perform(action: String) -> Bool {
    guard let surface else { return false }
    return action.withCString {
      ghostty_surface_binding_action(surface, $0, UInt(action.utf8.count))
    }
  }

  func openHoveredLink() {
    guard let hoveredLinkURL, let url = URL(string: hoveredLinkURL) else { return }
    NSWorkspace.shared.open(url)
  }

  var hasHoveredLink: Bool { hoveredLinkURL != nil }

  func appearanceChanged(_ appearance: NSAppearance) {
    applyColorScheme(colorScheme, appearance: appearance)
  }

  func applyColorScheme(
    _ colorScheme: FeatherGhosttyColorScheme,
    appearance: NSAppearance? = nil
  ) {
    self.colorScheme = colorScheme
    guard
      let surface,
      let resolved = resolveGhosttyColorScheme(
        colorScheme,
        appearance: appearance ?? view?.effectiveAppearance
      )
    else { return }
    ghostty_surface_set_color_scheme(surface, resolved)
    ghostty_surface_refresh(surface)
  }

  func updateConfig(_ config: ghostty_config_t) {
    guard let surface else { return }
    ghostty_surface_update_config(surface, config)
    applyColorScheme(colorScheme, appearance: view?.effectiveAppearance)
  }

  @discardableResult
  func handle(action: FeatherGhosttyAction) -> Bool {
    let handled: Bool
    switch action {
    case .hoveredLink(let url):
      hoveredLinkURL = url
      handled = true
    case .openURL(let value):
      if let value, let url = URL(string: value) {
        NSWorkspace.shared.open(url)
        handled = true
      } else {
        handled = false
      }
    case .render:
      requestRender()
      handled = true
    case .openConfig:
      handled = true
    case .reloadConfig:
      host.reloadConfig()
      handled = true
    case .ringBell:
      NSSound.beep()
      handled = true
    case .secureInput(let enabled):
      if enabled != secureEventInputEnabled {
        if enabled {
          EnableSecureEventInput()
        } else {
          DisableSecureEventInput()
        }
        secureEventInputEnabled = enabled
      }
      handled = true
    case .request(let request):
      requestHandler?(request)
      handled = true
    case .mouseShape(let shape):
      view?.applyCursor(shape)
      handled = true
    case .mouseVisibility(let hidden):
      view?.setCursorHidden(hidden)
      handled = true
    case .desktopNotification, .progress, .childExited, .commandFinished:
      handled = true
    case .unsupported:
      handled = false
    }
    actionHandler?(action)
    return handled
  }

  private func createSurface(in view: NSView) {
    guard let app = host.app else { return }
    if let resolved = resolveGhosttyColorScheme(colorScheme, appearance: view.effectiveAppearance) {
      ghostty_app_set_color_scheme(app, resolved)
    }

    var config = ghostty_surface_config_new()
    config.platform_tag = GHOSTTY_PLATFORM_MACOS
    config.platform = ghostty_platform_u(
      macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(view).toOpaque())
    )
    config.userdata = Unmanaged.passUnretained(self).toOpaque()
    config.scale_factor = Double(
      view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    )
    config.context = GHOSTTY_SURFACE_CONTEXT_WINDOW

    workingDirectory.withCString { workingDirectory in
      config.working_directory = workingDirectory
      surface = ghostty_surface_new(app, &config)
    }

    if let surface,
      let resolved = resolveGhosttyColorScheme(colorScheme, appearance: view.effectiveAppearance)
    {
      ghostty_surface_set_color_scheme(surface, resolved)
    }
  }

  private func updateContentScale(_ scale: CGFloat) {
    guard let surface else { return }
    ghostty_surface_set_content_scale(surface, Double(scale), Double(scale))
  }

  private func resize(to size: CGSize, scale: CGFloat) {
    guard let surface else { return }
    guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
      return
    }
    ghostty_surface_set_size(
      surface,
      UInt32(ceil(size.width * scale)),
      UInt32(ceil(size.height * scale))
    )
    ghostty_surface_refresh(surface)
  }

  private func setDisplayID(_ displayID: CGDirectDisplayID?) {
    guard let surface, let displayID else { return }
    ghostty_surface_set_display_id(surface, displayID)
  }

  private func sendKeyEvent(
    _ event: NSEvent,
    action: ghostty_input_action_e,
    text: String?
  ) {
    guard let surface else { return }
    var key = ghostty_input_key_s()
    key.action = action
    key.keycode = UInt32(event.keyCode)
    key.mods = translateModifiers(event.modifierFlags)
    key.consumed_mods = ghostty_surface_key_translation_mods(surface, key.mods)
    key.unshifted_codepoint = event.charactersIgnoringModifiers?.unicodeScalars.first?.value ?? 0

    if let text, !text.isEmpty {
      text.withCString {
        key.text = $0
        _ = ghostty_surface_key(surface, key)
      }
    } else {
      _ = ghostty_surface_key(surface, key)
    }
  }

  private func translate(_ button: FeatherGhosttyMouseButton) -> ghostty_input_mouse_button_e {
    switch button {
    case .left: GHOSTTY_MOUSE_LEFT
    case .right: GHOSTTY_MOUSE_RIGHT
    case .middle: GHOSTTY_MOUSE_MIDDLE
    case .other(let number):
      switch number {
      case 3: GHOSTTY_MOUSE_FOUR
      case 4: GHOSTTY_MOUSE_FIVE
      case 5: GHOSTTY_MOUSE_SIX
      case 6: GHOSTTY_MOUSE_SEVEN
      case 7: GHOSTTY_MOUSE_EIGHT
      case 8: GHOSTTY_MOUSE_NINE
      case 9: GHOSTTY_MOUSE_TEN
      case 10: GHOSTTY_MOUSE_ELEVEN
      default: GHOSTTY_MOUSE_UNKNOWN
      }
    }
  }

  private func translateModifiers(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
    var raw = UInt32(GHOSTTY_MODS_NONE.rawValue)
    if flags.contains(.shift) { raw |= UInt32(GHOSTTY_MODS_SHIFT.rawValue) }
    if flags.contains(.control) { raw |= UInt32(GHOSTTY_MODS_CTRL.rawValue) }
    if flags.contains(.option) { raw |= UInt32(GHOSTTY_MODS_ALT.rawValue) }
    if flags.contains(.command) { raw |= UInt32(GHOSTTY_MODS_SUPER.rawValue) }
    if flags.contains(.capsLock) { raw |= UInt32(GHOSTTY_MODS_CAPS.rawValue) }
    return ghostty_input_mods_e(raw)
  }

  private func translateScrollModifiers(_ event: NSEvent) -> ghostty_input_scroll_mods_t {
    var value = ghostty_input_scroll_mods_t(translateModifiers(event.modifierFlags).rawValue)
    switch event.momentumPhase {
    case .began:
      value |= ghostty_input_scroll_mods_t(GHOSTTY_MOUSE_MOMENTUM_BEGAN.rawValue << 16)
    case .changed:
      value |= ghostty_input_scroll_mods_t(GHOSTTY_MOUSE_MOMENTUM_CHANGED.rawValue << 16)
    case .ended:
      value |= ghostty_input_scroll_mods_t(GHOSTTY_MOUSE_MOMENTUM_ENDED.rawValue << 16)
    case .cancelled:
      value |= ghostty_input_scroll_mods_t(GHOSTTY_MOUSE_MOMENTUM_CANCELLED.rawValue << 16)
    case .mayBegin:
      value |= ghostty_input_scroll_mods_t(GHOSTTY_MOUSE_MOMENTUM_MAY_BEGIN.rawValue << 16)
    default:
      break
    }
    if event.hasPreciseScrollingDeltas { value |= 1 << 24 }
    return value
  }
}

enum FeatherGhosttyMouseButton {
  case left
  case right
  case middle
  case other(Int)
}

@MainActor
final class FeatherGhosttyView: NSView, @preconcurrency NSTextInputClient {
  private(set) weak var session: FeatherGhosttySession?
  private var trackingAreaReference: NSTrackingArea?
  private var markedText = NSMutableAttributedString()
  private var keyTextAccumulator: [String]?
  private var renderScheduled = false
  private var observedWindow: NSWindow?
  private var cursorHidden = false
  nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

  var currentDisplayID: CGDirectDisplayID? {
    guard
      let number = window?.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
        as? NSNumber
    else { return nil }
    return CGDirectDisplayID(number.uint32Value)
  }

  override init(frame: NSRect = NSRect(x: 0, y: 0, width: 800, height: 500)) {
    super.init(frame: frame)
    wantsLayer = true
    layerContentsRedrawPolicy = .onSetNeedsDisplay
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  deinit {
    removeObservers()
  }

  override var acceptsFirstResponder: Bool { true }
  override var wantsUpdateLayer: Bool { true }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  func attach(session: FeatherGhosttySession) {
    self.session = session
  }

  func detach() {
    session = nil
    renderScheduled = false
    removeObservers()
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    updateObservers()
    session?.synchronizeGeometry()
    session?.setFocused(window?.firstResponder === self)
    session?.setOccluded(window?.occlusionState.contains(.visible) == false)
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let trackingAreaReference { removeTrackingArea(trackingAreaReference) }
    let area = NSTrackingArea(
      rect: bounds,
      options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
      owner: self
    )
    addTrackingArea(area)
    trackingAreaReference = area
  }

  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    session?.synchronizeGeometry()
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    session?.appearanceChanged(effectiveAppearance)
  }

  override func layout() {
    super.layout()
    session?.resize(to: bounds.size)
  }

  override func updateLayer() {
    requestRender()
  }

  override func becomeFirstResponder() -> Bool {
    session?.setFocused(true)
    return true
  }

  override func resignFirstResponder() -> Bool {
    session?.setFocused(false)
    return true
  }

  override func keyDown(with event: NSEvent) {
    keyTextAccumulator = []
    interpretKeyEvents([event])
    let text = keyTextAccumulator?.joined()
    keyTextAccumulator = nil
    session?.sendKeyDown(event, text: text?.isEmpty == true ? nil : text)
  }

  override func keyUp(with event: NSEvent) {
    session?.sendKeyUp(event)
  }

  override func flagsChanged(with event: NSEvent) {
    session?.sendMousePosition(event)
    super.flagsChanged(with: event)
  }

  override func mouseDown(with event: NSEvent) {
    requestWindowFirstResponder()
    session?.sendMousePosition(event)
    _ = session?.sendMouseButton(.left, pressed: true, event: event)
  }

  override func mouseUp(with event: NSEvent) {
    session?.sendMousePosition(event)
    _ = session?.sendMouseButton(.left, pressed: false, event: event)
  }

  override func rightMouseDown(with event: NSEvent) {
    requestWindowFirstResponder()
    session?.sendMousePosition(event)
    if session?.sendMouseButton(.right, pressed: true, event: event) != true {
      NSMenu.popUpContextMenu(makeContextMenu(), with: event, for: self)
    }
  }

  override func rightMouseUp(with event: NSEvent) {
    session?.sendMousePosition(event)
    _ = session?.sendMouseButton(.right, pressed: false, event: event)
  }

  override func otherMouseDown(with event: NSEvent) {
    requestWindowFirstResponder()
    session?.sendMousePosition(event)
    _ = session?.sendMouseButton(
      .other(Int(event.buttonNumber)),
      pressed: true,
      event: event
    )
  }

  override func otherMouseUp(with event: NSEvent) {
    session?.sendMousePosition(event)
    _ = session?.sendMouseButton(
      .other(Int(event.buttonNumber)),
      pressed: false,
      event: event
    )
  }

  override func mouseEntered(with event: NSEvent) { session?.sendMousePosition(event) }
  override func mouseMoved(with event: NSEvent) { session?.sendMousePosition(event) }
  override func mouseDragged(with event: NSEvent) { session?.sendMousePosition(event) }
  override func rightMouseDragged(with event: NSEvent) { session?.sendMousePosition(event) }
  override func otherMouseDragged(with event: NSEvent) { session?.sendMousePosition(event) }

  override func mouseExited(with event: NSEvent) {
    session?.sendMouseExit(modifiers: event.modifierFlags)
  }

  override func scrollWheel(with event: NSEvent) {
    session?.sendScrollWheel(event)
  }

  @objc func copy(_ sender: Any?) {
    guard let text = session?.copySelection(), !text.isEmpty else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }

  @objc func paste(_ sender: Any?) {
    guard let text = NSPasteboard.general.string(forType: .string) else { return }
    session?.insertText(text)
  }

  override func selectAll(_ sender: Any?) {
    _ = session?.perform(action: "select_all")
  }

  @objc private func openHoveredLink(_ sender: Any?) {
    session?.openHoveredLink()
  }

  func requestRender() {
    guard !renderScheduled else { return }
    if let window, !window.occlusionState.contains(.visible) { return }
    renderScheduled = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.renderScheduled = false
      self.session?.render()
    }
  }

  func applyCursor(_ shape: ghostty_action_mouse_shape_e) {
    switch shape {
    case GHOSTTY_MOUSE_SHAPE_TEXT, GHOSTTY_MOUSE_SHAPE_VERTICAL_TEXT:
      NSCursor.iBeam.set()
    case GHOSTTY_MOUSE_SHAPE_POINTER:
      NSCursor.pointingHand.set()
    case GHOSTTY_MOUSE_SHAPE_CROSSHAIR:
      NSCursor.crosshair.set()
    case GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED, GHOSTTY_MOUSE_SHAPE_NO_DROP:
      NSCursor.operationNotAllowed.set()
    case GHOSTTY_MOUSE_SHAPE_COL_RESIZE, GHOSTTY_MOUSE_SHAPE_EW_RESIZE:
      NSCursor.resizeLeftRight.set()
    case GHOSTTY_MOUSE_SHAPE_ROW_RESIZE, GHOSTTY_MOUSE_SHAPE_NS_RESIZE:
      NSCursor.resizeUpDown.set()
    case GHOSTTY_MOUSE_SHAPE_GRAB, GHOSTTY_MOUSE_SHAPE_GRABBING:
      NSCursor.openHand.set()
    default:
      NSCursor.arrow.set()
    }
  }

  func setCursorHidden(_ hidden: Bool) {
    guard cursorHidden != hidden else { return }
    cursorHidden = hidden
    NSCursor.setHiddenUntilMouseMoves(hidden)
  }

  func hasMarkedText() -> Bool { markedText.length > 0 }

  func markedRange() -> NSRange {
    hasMarkedText()
      ? NSRange(location: 0, length: markedText.length)
      : NSRange(location: NSNotFound, length: 0)
  }

  func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }

  func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
    let text = Self.plainString(string) ?? ""
    markedText = NSMutableAttributedString(string: text)
    session?.setMarkedText(text.isEmpty ? nil : text)
  }

  func unmarkText() {
    markedText = NSMutableAttributedString()
    session?.setMarkedText(nil)
  }

  func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

  func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?)
    -> NSAttributedString?
  {
    nil
  }

  func characterIndex(for point: NSPoint) -> Int { 0 }

  func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
    guard let window else { return .zero }
    return window.convertToScreen(convert(bounds, to: nil))
  }

  func insertText(_ string: Any, replacementRange: NSRange) {
    guard let text = Self.plainString(string) else { return }
    unmarkText()
    if keyTextAccumulator != nil {
      keyTextAccumulator?.append(text)
    } else {
      session?.insertText(text)
    }
  }

  override func doCommand(by selector: Selector) {
    if selector == #selector(NSResponder.moveToBeginningOfDocument(_:)) {
      _ = session?.perform(action: "scroll_to_top")
      return
    }
    if selector == #selector(NSResponder.moveToEndOfDocument(_:)) {
      _ = session?.perform(action: "scroll_to_bottom")
      return
    }
    if Self.suppressesSystemTextCommand(selector) { return }
    super.doCommand(by: selector)
  }

  private func updateObservers() {
    guard observedWindow !== window else { return }
    removeObservers()
    observedWindow = window
    let center = NotificationCenter.default

    if let window {
      observers.append(
        center.addObserver(
          forName: NSWindow.didChangeOcclusionStateNotification,
          object: window,
          queue: .main
        ) { [weak self, weak window] _ in
          Task { @MainActor in
            guard let self, let window else { return }
            self.session?.setOccluded(!window.occlusionState.contains(.visible))
          }
        }
      )
      observers.append(
        center.addObserver(
          forName: NSWindow.didChangeScreenNotification,
          object: window,
          queue: .main
        ) { [weak self] _ in
          Task { @MainActor in
            self?.session?.synchronizeGeometry()
            DispatchQueue.main.async { [weak self] in
              self?.session?.synchronizeGeometry()
            }
          }
        }
      )
    }

    observers.append(
      center.addObserver(
        forName: NSTextInputContext.keyboardSelectionDidChangeNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor in self?.session?.keyboardLayoutChanged() }
      }
    )
  }

  nonisolated private func removeObservers() {
    for observer in observers {
      NotificationCenter.default.removeObserver(observer)
    }
    observers.removeAll()
  }

  private func requestWindowFirstResponder() {
    guard let window else { return }
    if !window.isKeyWindow { window.makeKeyAndOrderFront(nil) }
    if window.firstResponder !== self { window.makeFirstResponder(self) }
  }

  private func makeContextMenu() -> NSMenu {
    let menu = NSMenu()
    menu.addItem(menuItem("Copy", #selector(copy(_:)), enabled: session?.hasSelection() == true))
    menu.addItem(
      menuItem(
        "Paste",
        #selector(paste(_:)),
        enabled: NSPasteboard.general.string(forType: .string) != nil
      )
    )
    menu.addItem(menuItem("Select All", #selector(selectAll(_:)), enabled: session != nil))
    menu.addItem(NSMenuItem.separator())
    menu.addItem(
      menuItem(
        "Open Link",
        #selector(openHoveredLink(_:)),
        enabled: session?.hasHoveredLink == true
      )
    )
    return menu
  }

  private func menuItem(_ title: String, _ action: Selector, enabled: Bool) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
    item.target = self
    item.isEnabled = enabled
    return item
  }

  private static func plainString(_ value: Any) -> String? {
    switch value {
    case let string as String: string
    case let attributed as NSAttributedString: attributed.string
    default: nil
    }
  }

  private static func suppressesSystemTextCommand(_ selector: Selector) -> Bool {
    selector == #selector(NSResponder.insertNewline(_:))
      || selector == #selector(NSResponder.insertLineBreak(_:))
      || selector == #selector(NSResponder.insertTab(_:))
      || selector == #selector(NSResponder.insertBacktab(_:))
      || selector == #selector(NSResponder.deleteBackward(_:))
      || selector == #selector(NSResponder.deleteForward(_:))
      || selector == #selector(NSResponder.deleteWordBackward(_:))
      || selector == #selector(NSResponder.deleteWordForward(_:))
      || selector == #selector(NSResponder.moveUp(_:))
      || selector == #selector(NSResponder.moveDown(_:))
      || selector == #selector(NSResponder.moveLeft(_:))
      || selector == #selector(NSResponder.moveRight(_:))
      || selector == #selector(NSResponder.moveWordLeft(_:))
      || selector == #selector(NSResponder.moveWordRight(_:))
      || selector == #selector(NSResponder.moveToBeginningOfLine(_:))
      || selector == #selector(NSResponder.moveToEndOfLine(_:))
      || selector == #selector(NSResponder.pageUp(_:))
      || selector == #selector(NSResponder.pageDown(_:))
      || selector == #selector(NSResponder.cancelOperation(_:))
  }
}

@MainActor
func resolveGhosttyColorScheme(
  _ colorScheme: FeatherGhosttyColorScheme,
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
