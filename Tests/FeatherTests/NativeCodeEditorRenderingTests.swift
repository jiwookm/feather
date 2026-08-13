import AppKit
import SwiftUI
import Testing

@testable import Feather

struct NativeCodeEditorRenderingTests {
  @Test @MainActor
  func rendersEditorGlyphsIntoAnOffscreenHostingView() throws {
    for isDark in [true, false] {
      let editor = NativeCodeTextView(
        text: .constant("let answer = 42\nprint(answer)\n"),
        path: "Example.swift",
        isDark: isDark,
        wrapsLines: false
      )
      let host = NSHostingView(rootView: editor)
      host.frame = NSRect(x: 0, y: 0, width: 640, height: 360)
      host.wantsLayer = true
      host.layoutSubtreeIfNeeded()
      host.displayIfNeeded()

      let bitmap = try #require(
        host.bitmapImageRepForCachingDisplay(in: host.bounds)
      )
      host.cacheDisplay(in: host.bounds, to: bitmap)

      #expect(syntaxPixelCount(in: bitmap, isDark: isDark) > 10)

      let layerBitmap = try #require(
        NSBitmapImageRep(
          bitmapDataPlanes: nil,
          pixelsWide: 640,
          pixelsHigh: 360,
          bitsPerSample: 8,
          samplesPerPixel: 4,
          hasAlpha: true,
          isPlanar: false,
          colorSpaceName: .deviceRGB,
          bytesPerRow: 0,
          bitsPerPixel: 0
        )
      )
      let graphics = try #require(NSGraphicsContext(bitmapImageRep: layerBitmap))
      host.layer?.render(in: graphics.cgContext)
      #expect(syntaxPixelCount(in: layerBitmap, isDark: isDark) > 10)
    }
  }

  private func syntaxPixelCount(in bitmap: NSBitmapImageRep, isDark: Bool) -> Int {
    let expected =
      (isDark
      ? [NSColor(hex: 0xD6DEEB), NSColor(hex: 0xC792EA), NSColor(hex: 0x82AAFF)]
      : [NSColor(hex: 0x242424), NSColor(hex: 0x7C3AED), NSColor(hex: 0x2457A6)])
      .compactMap { $0.usingColorSpace(.sRGB) }
    let xStart = min(bitmap.pixelsWide, Int(Double(bitmap.pixelsWide) * 0.08))
    let xEnd = min(bitmap.pixelsWide, Int(Double(bitmap.pixelsWide) * 0.5))
    return stride(from: xStart, to: xEnd, by: 2).reduce(0) { count, x in
      count
        + stride(from: 0, to: bitmap.pixelsHigh, by: 2).filter { y in
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
