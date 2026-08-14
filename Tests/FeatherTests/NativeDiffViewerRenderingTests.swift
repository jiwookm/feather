import AppKit
import FeatherCore
import SwiftUI
import Testing

@testable import Feather

struct NativeDiffViewerRenderingTests {
  @Test @MainActor
  func rendersUnifiedAndSplitDiffsOffscreen() throws {
    let document = UnifiedDiffDocument.parse(
      """
      diff --git a/Example.swift b/Example.swift
      index 1111111..2222222 100644
      --- a/Example.swift
      +++ b/Example.swift
      @@ -1,2 +1,2 @@
      -let answer = 41
      +let answer = 42
       print(answer)
      """
    )

    for isDark in [true, false] {
      for layout in NativeDiffLayout.allCases {
        let viewer = NativeDiffViewer(
          document: document,
          path: "Example.swift",
          isDark: isDark,
          layout: layout
        )
        let host = NSHostingView(rootView: viewer)
        host.frame = NSRect(x: 0, y: 0, width: 720, height: 420)
        host.wantsLayer = true
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()

        let bitmap = try #require(
          host.bitmapImageRepForCachingDisplay(in: host.bounds)
        )
        host.cacheDisplay(in: host.bounds, to: bitmap)
        #expect(
          pixelCount(
            in: bitmap,
            hexes: isDark ? [0xADDB67, 0xEF5350] : [0x357A14, 0xB42318]
          ) > 10,
          "\(layout.rawValue) diff did not render in \(isDark ? "Dark" : "Light") mode"
        )
        if layout == .split {
          let midpoint = bitmap.pixelsWide / 2
          #expect(
            pixelCount(
              in: bitmap,
              hexes: [isDark ? 0xEF5350 : 0xB42318],
              xRange: 0..<midpoint,
              samplingStride: 1
            ) > 10,
            "Original split pane did not render deletions"
          )
          #expect(
            pixelCount(
              in: bitmap,
              hexes: [isDark ? 0xADDB67 : 0x357A14],
              xRange: midpoint..<bitmap.pixelsWide,
              samplingStride: 1
            ) > 10,
            "Modified split pane did not render additions"
          )
        }
      }
    }
  }

  @Test @MainActor
  func narrowDiffsWrapInsideTheirPaneAndKeepSplitRowsAligned() throws {
    let longValue = String(repeating: "abcdefghij", count: 28)
    let document = UnifiedDiffDocument.parse(
      """
      diff --git a/Example.swift b/Example.swift
      index 1111111..2222222 100644
      --- a/Example.swift
      +++ b/Example.swift
      @@ -1 +1 @@
      -let original = "\(longValue)"
      +let replacement = "short"
      """
    )

    for layout in NativeDiffLayout.allCases {
      let host = NSHostingView(
        rootView: NativeDiffViewer(
          document: document,
          path: "Example.swift",
          isDark: false,
          layout: layout
        )
      )
      host.frame = NSRect(x: 0, y: 0, width: 340, height: 420)
      host.layoutSubtreeIfNeeded()
      host.displayIfNeeded()

      let scrollViews = descendants(of: NSScrollView.self, in: host)
      #expect(scrollViews.count == (layout == .split ? 2 : 1))
      for scrollView in scrollViews {
        #expect(!scrollView.hasHorizontalScroller)
        let textView = try #require(scrollView.documentView as? NSTextView)
        #expect(textView.textContainer?.widthTracksTextView == true)
        #expect(textView.frame.width <= scrollView.contentSize.width + 1)
      }

      if layout == .split {
        let heights = try scrollViews.map { scrollView in
          let textView = try #require(scrollView.documentView as? NSTextView)
          let layoutManager = try #require(textView.layoutManager)
          let container = try #require(textView.textContainer)
          layoutManager.ensureLayout(for: container)
          return layoutManager.usedRect(for: container).height
        }
        #expect(abs(heights[0] - heights[1]) < 1)
      }
    }
  }

  @MainActor
  private func descendants<T: NSView>(of type: T.Type, in view: NSView) -> [T] {
    let direct = view.subviews.compactMap { $0 as? T }
    return direct + view.subviews.flatMap { descendants(of: type, in: $0) }
  }

  private func pixelCount(
    in bitmap: NSBitmapImageRep,
    hexes: [UInt32],
    xRange: Range<Int>? = nil,
    samplingStride: Int = 2
  ) -> Int {
    let expected = hexes.compactMap { NSColor(hex: $0).usingColorSpace(.sRGB) }
    let horizontalRange = xRange ?? 0..<bitmap.pixelsWide
    return stride(
      from: horizontalRange.lowerBound,
      to: horizontalRange.upperBound,
      by: samplingStride
    )
    .reduce(0) { count, x in
      count
        + stride(from: 0, to: bitmap.pixelsHigh, by: samplingStride).filter { y in
          guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else {
            return false
          }
          return expected.contains { target in
            abs(color.redComponent - target.redComponent) < 0.16
              && abs(color.greenComponent - target.greenComponent) < 0.16
              && abs(color.blueComponent - target.blueComponent) < 0.16
          }
        }.count
    }
  }
}
