import AppKit
import Testing

@testable import Feather

struct WindowChromeTests {
  @Test @MainActor
  func trafficLightsAlignToTheRenderedTitlebarCenter() throws {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    let contentView = try #require(window.contentView)
    let alignmentGuide = NSView(
      frame: NSRect(
        x: 0,
        y: contentView.bounds.maxY - FeatherMetrics.titlebarHeight(false),
        width: contentView.bounds.width,
        height: FeatherMetrics.titlebarHeight(false)
      )
    )
    contentView.addSubview(alignmentGuide)

    FeatherWindow.alignWindowButtons(in: window, with: alignmentGuide)

    let expectedCenter = alignmentGuide.convert(
      NSPoint(x: alignmentGuide.bounds.midX, y: alignmentGuide.bounds.midY),
      to: nil
    ).y
    for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
      let button = try #require(window.standardWindowButton(kind))
      let container = try #require(button.superview)
      let actualCenter = container.convert(
        NSPoint(x: button.frame.midX, y: button.frame.midY),
        to: nil
      ).y
      #expect(abs(actualCenter - expectedCenter) < 0.001)
    }
  }
}
