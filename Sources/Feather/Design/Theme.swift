import AppKit
import SwiftUI

struct FeatherPalette {
  let colorScheme: ColorScheme

  var isDark: Bool { colorScheme == .dark }

  var titlebar: Color { Color(hex: isDark ? 0x1E1E1E : 0xF7F7F7) }
  var sidebar: Color { Color(hex: isDark ? 0x313131 : 0xF0F0F0) }
  var selection: Color { Color(hex: isDark ? 0x3E3E3E : 0xDFDFDF) }
  var terminal: Color { Color(hex: isDark ? 0x0D0D0D : 0xF7F7F7) }
  var border: Color { Color(hex: isDark ? 0x484848 : 0xD1D1D1) }
  var primaryText: Color { Color(hex: isDark ? 0xE7E7E7 : 0x242424) }
  var secondaryText: Color { Color(hex: isDark ? 0xA8A8A8 : 0x666666) }
  var mutedText: Color { Color(hex: isDark ? 0x777777 : 0x8A8A8A) }
  var accent: Color { Color(hex: isDark ? 0xADDB67 : 0x527A12) }
  var hover: Color { Color.white.opacity(isDark ? 0.055 : 0.4) }
}

enum FeatherMetrics {
  static func titlebarHeight(_ isFullScreen: Bool) -> CGFloat {
    isFullScreen ? 44 : 42
  }
}

extension Color {
  init(hex: UInt32) {
    self.init(
      .sRGB,
      red: Double((hex >> 16) & 0xFF) / 255,
      green: Double((hex >> 8) & 0xFF) / 255,
      blue: Double(hex & 0xFF) / 255,
      opacity: 1
    )
  }
}

extension NSColor {
  convenience init(hex: UInt32) {
    let red = CGFloat((hex >> 16) & 0xFF) / 255
    let green = CGFloat((hex >> 8) & 0xFF) / 255
    let blue = CGFloat(hex & 0xFF) / 255
    self.init(
      srgbRed: red,
      green: green,
      blue: blue,
      alpha: 1
    )
  }
}

@MainActor
enum FeatherWindow {
  static weak var workspace: NSWindow?
  private static weak var titlebarAlignmentGuide: NSView?
  private static var windowObservers: [NSObjectProtocol] = []
  private static var alignmentScheduled = false

  static func track(_ window: NSWindow, titlebarAlignmentGuide: NSView) {
    self.titlebarAlignmentGuide = titlebarAlignmentGuide

    if workspace !== window {
      for observer in windowObservers {
        NotificationCenter.default.removeObserver(observer)
      }
      windowObservers.removeAll()
      workspace = window

      for name in [
        NSWindow.didResizeNotification,
        NSWindow.didChangeScreenNotification,
        NSWindow.didChangeBackingPropertiesNotification,
        NSWindow.didExitFullScreenNotification,
      ] {
        windowObservers.append(
          NotificationCenter.default.addObserver(
            forName: name,
            object: window,
            queue: .main
          ) { [weak window] _ in
            Task { @MainActor in
              guard let window, window === workspace else { return }
              scheduleWindowButtonAlignment()
            }
          }
        )
      }
    }

    scheduleWindowButtonAlignment()
  }

  static func scheduleWindowButtonAlignment() {
    guard !alignmentScheduled else { return }
    alignmentScheduled = true
    DispatchQueue.main.async {
      alignmentScheduled = false
      alignWindowButtons()
    }
  }

  static func alignWindowButtons() {
    guard let window = workspace, let titlebarAlignmentGuide else { return }
    alignWindowButtons(in: window, with: titlebarAlignmentGuide)
  }

  static func alignWindowButtons(in window: NSWindow, with titlebarAlignmentGuide: NSView) {
    guard !window.styleMask.contains(.fullScreen),
      titlebarAlignmentGuide.window === window,
      titlebarAlignmentGuide.bounds.height > 0
    else { return }

    let guideCenter = titlebarAlignmentGuide.convert(
      NSPoint(x: titlebarAlignmentGuide.bounds.midX, y: titlebarAlignmentGuide.bounds.midY),
      to: nil
    )

    for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
      guard let button = window.standardWindowButton(kind), let container = button.superview else {
        continue
      }
      let target = container.convert(guideCenter, from: nil).y - button.frame.height / 2
      button.setFrameOrigin(NSPoint(x: button.frame.minX, y: target))
    }
  }
}

extension Font {
  static func feather(size: CGFloat, weight: Weight = .regular) -> Font {
    .custom("Geist", fixedSize: size).weight(weight)
  }
}

struct HoverButtonStyle: ButtonStyle {
  @Environment(\.colorScheme) private var colorScheme

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .foregroundStyle(FeatherPalette(colorScheme: colorScheme).secondaryText)
      .padding(5)
      .background(
        configuration.isPressed ? FeatherPalette(colorScheme: colorScheme).hover : .clear
      )
      .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
      .contentShape(Rectangle())
  }
}

struct WindowDragSurface: NSViewRepresentable {
  func makeNSView(context: Context) -> NSView { DragView() }
  func updateNSView(_ nsView: NSView, context: Context) {
    guard let window = nsView.window else { return }
    FeatherWindow.track(window, titlebarAlignmentGuide: nsView)
  }

  private final class DragView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if let window {
        FeatherWindow.track(window, titlebarAlignmentGuide: self)
      }
    }

    override func layout() {
      super.layout()
      guard let window else { return }
      FeatherWindow.track(window, titlebarAlignmentGuide: self)
    }

    override func viewDidChangeBackingProperties() {
      super.viewDidChangeBackingProperties()
      guard let window else { return }
      FeatherWindow.track(window, titlebarAlignmentGuide: self)
    }
  }
}
