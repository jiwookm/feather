import AppKit
import FeatherCore
import SwiftUI

enum NativeDiffLayout: String, CaseIterable, Identifiable {
  case unified = "Unified"
  case split = "Split"

  var id: String { rawValue }
}

struct NativeDiffViewer: View {
  let document: UnifiedDiffDocument
  let path: String
  let isDark: Bool
  let layout: NativeDiffLayout
  let wrapsLines: Bool

  var body: some View {
    switch layout {
    case .unified:
      NativeUnifiedDiffTextView(
        document: document,
        path: path,
        isDark: isDark,
        wrapsLines: wrapsLines
      )
    case .split:
      VStack(spacing: 0) {
        HStack(spacing: 0) {
          sideLabel("Original")
          Divider()
          sideLabel("Modified")
        }
        .frame(height: 27)
        .background(Color(nsColor: NSColor(hex: isDark ? 0x151515 : 0xF7F7F7)))
        NativeSplitDiffTextView(document: document, path: path, isDark: isDark)
      }
    }
  }

  private func sideLabel(_ title: String) -> some View {
    Text(title)
      .font(.feather(size: 10, weight: .medium))
      .foregroundStyle(Color(nsColor: NSColor(hex: isDark ? 0x7E8A9A : 0x737373)))
      .padding(.horizontal, 10)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct NativeUnifiedDiffTextView: NSViewRepresentable {
  let document: UnifiedDiffDocument
  let path: String
  let isDark: Bool
  let wrapsLines: Bool

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> TextSurfaceContainerView {
    TextSurfaceContainerView(scrollView: DiffTextSurface.makeScrollView())
  }

  func updateNSView(_ container: TextSurfaceContainerView, context: Context) {
    let scrollView = container.scrollView
    guard let textView = scrollView.documentView as? NSTextView else { return }
    DiffTextSurface.configure(
      scrollView, textView: textView, isDark: isDark, wrapsLines: wrapsLines)
    let changed =
      context.coordinator.document != document || context.coordinator.path != path
      || context.coordinator.isDark != isDark
    guard changed else { return }
    context.coordinator.document = document
    context.coordinator.path = path
    context.coordinator.isDark = isDark
    textView.textStorage?.setAttributedString(
      DiffAttributedText.unified(document, path: path, isDark: isDark)
    )
    DiffTextSurface.refresh(textView)
  }

  final class Coordinator {
    var document: UnifiedDiffDocument?
    var path: String?
    var isDark: Bool?
  }
}

private struct NativeSplitDiffTextView: NSViewRepresentable {
  let document: UnifiedDiffDocument
  let path: String
  let isDark: Bool

  func makeNSView(context: Context) -> SynchronizedDiffContainer {
    SynchronizedDiffContainer()
  }

  func updateNSView(_ view: SynchronizedDiffContainer, context: Context) {
    view.update(document: document, path: path, isDark: isDark)
  }
}

@MainActor
private final class SynchronizedDiffContainer: NSView {
  private let leftScrollView = DiffTextSurface.makeScrollView()
  private let rightScrollView = DiffTextSurface.makeScrollView()
  private let divider = NSView()
  private var isSynchronizing = false
  private var document: UnifiedDiffDocument?
  private var path: String?
  private var isDark: Bool?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    divider.wantsLayer = true
    addSubview(leftScrollView)
    addSubview(rightScrollView)
    addSubview(divider)
    for scrollView in [leftScrollView, rightScrollView] {
      scrollView.wantsLayer = true
      scrollView.contentView.wantsLayer = true
      scrollView.contentView.postsBoundsChangedNotifications = true
      NotificationCenter.default.addObserver(
        self,
        selector: #selector(scrolled(_:)),
        name: NSView.boundsDidChangeNotification,
        object: scrollView.contentView
      )
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  deinit { NotificationCenter.default.removeObserver(self) }

  override func layout() {
    super.layout()
    let dividerWidth: CGFloat = bounds.width > 0 ? 1 : 0
    let leftWidth = floor(max(0, bounds.width - dividerWidth) / 2)
    leftScrollView.frame = NSRect(x: 0, y: 0, width: leftWidth, height: bounds.height)
    divider.frame = NSRect(x: leftWidth, y: 0, width: dividerWidth, height: bounds.height)
    rightScrollView.frame = NSRect(
      x: leftWidth + dividerWidth,
      y: 0,
      width: max(0, bounds.width - leftWidth - dividerWidth),
      height: bounds.height
    )
    for scrollView in [leftScrollView, rightScrollView] {
      scrollView.tile()
      TextSurfaceContainerView.fitDocument(in: scrollView)
    }
  }

  func update(document: UnifiedDiffDocument, path: String, isDark: Bool) {
    for scrollView in [leftScrollView, rightScrollView] {
      guard let textView = scrollView.documentView as? NSTextView else { continue }
      DiffTextSurface.configure(scrollView, textView: textView, isDark: isDark, wrapsLines: false)
    }
    guard self.document != document || self.path != path || self.isDark != isDark else { return }
    self.document = document
    self.path = path
    self.isDark = isDark
    divider.layer?.backgroundColor = NSColor(hex: isDark ? 0x242424 : 0xE2E2E2).cgColor
    let sides = DiffAttributedText.split(document, path: path, isDark: isDark)
    if let textView = leftScrollView.documentView as? NSTextView {
      textView.textStorage?.setAttributedString(sides.left)
      DiffTextSurface.refresh(textView)
    }
    if let textView = rightScrollView.documentView as? NSTextView {
      textView.textStorage?.setAttributedString(sides.right)
      DiffTextSurface.refresh(textView)
    }
  }

  @objc private func scrolled(_ notification: Notification) {
    guard !isSynchronizing, let source = notification.object as? NSClipView else { return }
    let destinationScrollView =
      source === leftScrollView.contentView ? rightScrollView : leftScrollView
    let destination = destinationScrollView.contentView
    guard abs(destination.bounds.minY - source.bounds.minY) > 0.5 else { return }
    isSynchronizing = true
    destination.scroll(to: NSPoint(x: destination.bounds.minX, y: source.bounds.minY))
    destinationScrollView.reflectScrolledClipView(destination)
    isSynchronizing = false
  }
}

@MainActor
private enum DiffTextSurface {
  static func makeScrollView() -> NSScrollView {
    let scrollView = NSScrollView()
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.drawsBackground = true

    let storage = NSTextStorage()
    let layoutManager = DiffBackgroundLayoutManager()
    let container = NSTextContainer(
      size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
    )
    storage.addLayoutManager(layoutManager)
    layoutManager.addTextContainer(container)
    let textView = NSTextView(
      frame: NSRect(x: 0, y: 0, width: 100, height: 100),
      textContainer: container
    )
    textView.isEditable = false
    textView.isSelectable = true
    textView.isRichText = false
    textView.isVerticallyResizable = true
    textView.usesFindBar = true
    textView.isIncrementalSearchingEnabled = true
    textView.textContainerInset = NSSize(width: 8, height: 9)
    scrollView.documentView = textView
    return scrollView
  }

  static func configure(
    _ scrollView: NSScrollView,
    textView: NSTextView,
    isDark: Bool,
    wrapsLines: Bool
  ) {
    let background = NativeCodeStyle.background(isDark: isDark)
    scrollView.backgroundColor = background
    scrollView.hasHorizontalScroller = !wrapsLines
    textView.backgroundColor = background
    textView.isHorizontallyResizable = !wrapsLines
    textView.autoresizingMask = wrapsLines ? [.width] : []
    textView.textContainer?.widthTracksTextView = wrapsLines
    textView.textContainer?.heightTracksTextView = false
    textView.textContainer?.containerSize = NSSize(
      width: wrapsLines ? scrollView.contentSize.width : CGFloat.greatestFiniteMagnitude,
      height: CGFloat.greatestFiniteMagnitude
    )
    textView.minSize = NSSize(width: 0, height: scrollView.contentSize.height)
    textView.maxSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude,
      height: CGFloat.greatestFiniteMagnitude
    )
    (textView.layoutManager as? DiffBackgroundLayoutManager)?.minimumRowWidth =
      scrollView.contentSize.width
  }

  static func refresh(_ textView: NSTextView) {
    if let manager = textView.layoutManager, let container = textView.textContainer {
      manager.ensureLayout(for: container)
    }
    textView.needsDisplay = true
    textView.layer?.setNeedsDisplay()
  }
}

extension NSAttributedString.Key {
  fileprivate static let featherDiffBackground = NSAttributedString.Key("FeatherDiffBackground")
}

private final class DiffBackgroundLayoutManager: NSLayoutManager, ViewportWidthAwareLayout {
  var minimumRowWidth: CGFloat = 0

  override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
    guard let textStorage else {
      super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
      return
    }
    enumerateLineFragments(forGlyphRange: glyphsToShow) {
      lineRect, _, textContainer, glyphRange, _ in
      let characterIndex = self.characterIndexForGlyph(at: glyphRange.location)
      guard characterIndex < textStorage.length,
        let color = textStorage.attribute(
          .featherDiffBackground,
          at: characterIndex,
          effectiveRange: nil
        ) as? NSColor
      else { return }
      color.setFill()
      let usedWidth = self.usedRect(for: textContainer).width
      NSRect(
        x: origin.x,
        y: lineRect.minY + origin.y,
        width: max(self.minimumRowWidth, usedWidth),
        height: lineRect.height
      ).fill()
    }
    super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
  }
}

@MainActor
private enum DiffAttributedText {
  private static let maximumHighlightedLines = 2_000

  private struct Colors {
    let foreground: NSColor
    let muted: NSColor
    let addition: NSColor
    let deletion: NSColor
    let hunk: NSColor
    let additionBackground: NSColor
    let deletionBackground: NSColor
    let hunkBackground: NSColor
  }

  static func unified(
    _ document: UnifiedDiffDocument,
    path: String,
    isDark: Bool
  ) -> NSAttributedString {
    let result = NSMutableAttributedString()
    let highlightsCode = shouldHighlight(document)
    for line in document.lines {
      let gutter = "\(padded(line.oldLine)) \(padded(line.newLine))  \(marker(line.kind)) "
      append(
        line,
        gutter: gutter,
        path: path,
        isDark: isDark,
        highlightsCode: highlightsCode,
        to: result
      )
    }
    return result
  }

  static func split(
    _ document: UnifiedDiffDocument,
    path: String,
    isDark: Bool
  ) -> (left: NSAttributedString, right: NSAttributedString) {
    let left = NSMutableAttributedString()
    let right = NSMutableAttributedString()
    let highlightsCode = shouldHighlight(document)
    for row in document.splitRows {
      appendSide(
        row.left,
        oldSide: true,
        path: path,
        isDark: isDark,
        highlightsCode: highlightsCode,
        to: left
      )
      appendSide(
        row.right,
        oldSide: false,
        path: path,
        isDark: isDark,
        highlightsCode: highlightsCode,
        to: right
      )
    }
    return (left, right)
  }

  private static func appendSide(
    _ line: UnifiedDiffDocument.Line?,
    oldSide: Bool,
    path: String,
    isDark: Bool,
    highlightsCode: Bool,
    to result: NSMutableAttributedString
  ) {
    guard let line else {
      result.append(
        NSAttributedString(string: "       \n", attributes: baseAttributes(isDark: isDark))
      )
      return
    }
    let number = oldSide ? line.oldLine : line.newLine
    append(
      line,
      gutter: "\(padded(number))  \(marker(line.kind)) ",
      path: path,
      isDark: isDark,
      highlightsCode: highlightsCode,
      to: result
    )
  }

  private static func append(
    _ line: UnifiedDiffDocument.Line,
    gutter: String,
    path: String,
    isDark: Bool,
    highlightsCode: Bool,
    to result: NSMutableAttributedString
  ) {
    let colors = colors(isDark: isDark)
    let start = result.length
    var gutterAttributes = baseAttributes(isDark: isDark)
    gutterAttributes[.foregroundColor] = color(for: line.kind, colors: colors, gutter: true)
    result.append(NSAttributedString(string: gutter, attributes: gutterAttributes))

    if highlightsCode
      && (line.kind == .context || line.kind == .addition || line.kind == .deletion)
    {
      result.append(NativeCodeStyle.attributedCode(line.text, path: path, isDark: isDark))
    } else {
      var attributes = baseAttributes(isDark: isDark)
      attributes[.foregroundColor] = color(for: line.kind, colors: colors, gutter: false)
      result.append(NSAttributedString(string: line.text, attributes: attributes))
    }
    result.append(NSAttributedString(string: "\n", attributes: baseAttributes(isDark: isDark)))
    let range = NSRange(location: start, length: result.length - start)
    if let background = background(for: line.kind, colors: colors) {
      result.addAttribute(.featherDiffBackground, value: background, range: range)
    }
  }

  private static func baseAttributes(isDark: Bool) -> [NSAttributedString.Key: Any] {
    NativeCodeStyle.baseAttributes(isDark: isDark)
  }

  private static func codeLength(in document: UnifiedDiffDocument) -> Int {
    document.lines.reduce(into: 0) { length, line in
      length += line.text.utf16.count
    }
  }

  private static func shouldHighlight(_ document: UnifiedDiffDocument) -> Bool {
    document.lines.count <= maximumHighlightedLines
      && codeLength(in: document) <= NativeCodeStyle.maximumHighlightedCharacters
  }

  private static func marker(_ kind: UnifiedDiffDocument.Line.Kind) -> String {
    switch kind {
    case .addition: "+"
    case .deletion: "−"
    case .hunk: "@"
    case .metadata, .context: " "
    }
  }

  private static func padded(_ number: Int?) -> String {
    let value = number.map(String.init) ?? ""
    return String(repeating: " ", count: max(0, 5 - value.count)) + value
  }

  private static func colors(isDark: Bool) -> Colors {
    if isDark {
      return Colors(
        foreground: NSColor(hex: 0xD6DEEB),
        muted: NSColor(hex: 0x637777),
        addition: NSColor(hex: 0xADDB67),
        deletion: NSColor(hex: 0xEF5350),
        hunk: NSColor(hex: 0x82AAFF),
        additionBackground: NSColor(hex: 0x142B20),
        deletionBackground: NSColor(hex: 0x321B20),
        hunkBackground: NSColor(hex: 0x17243A)
      )
    }
    return Colors(
      foreground: NSColor(hex: 0x242424),
      muted: NSColor(hex: 0x737373),
      addition: NSColor(hex: 0x357A14),
      deletion: NSColor(hex: 0xB42318),
      hunk: NSColor(hex: 0x2457A6),
      additionBackground: NSColor(hex: 0xEAF6E7),
      deletionBackground: NSColor(hex: 0xFCE8E6),
      hunkBackground: NSColor(hex: 0xE9F2FF)
    )
  }

  private static func color(
    for kind: UnifiedDiffDocument.Line.Kind,
    colors: Colors,
    gutter: Bool
  ) -> NSColor {
    if gutter {
      return kind == .context ? colors.muted : color(for: kind, colors: colors, gutter: false)
    }
    switch kind {
    case .metadata: return colors.muted
    case .hunk: return colors.hunk
    case .context: return colors.foreground
    case .addition: return colors.addition
    case .deletion: return colors.deletion
    }
  }

  private static func background(
    for kind: UnifiedDiffDocument.Line.Kind,
    colors: Colors
  ) -> NSColor? {
    switch kind {
    case .addition: colors.additionBackground
    case .deletion: colors.deletionBackground
    case .hunk: colors.hunkBackground
    case .metadata, .context: nil
    }
  }
}
