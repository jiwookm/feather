import AppKit
import SwiftUI

protocol ViewportWidthAwareLayout: AnyObject {
  var minimumRowWidth: CGFloat { get set }
}

@MainActor
enum NativeCodeStyle {
  static let font =
    NSFont(name: "JetBrains Mono", size: 12)
    ?? .monospacedSystemFont(ofSize: 12, weight: .regular)
  static let lineHeight: CGFloat = 19
  static let maximumHighlightedCharacters = 768 * 1_024

  private enum Language: Equatable {
    case swift
    case javascript
    case python
    case shell
    case data
    case markup
    case generic
  }

  private struct Colors {
    let foreground: NSColor
    let keyword: NSColor
    let string: NSColor
    let number: NSColor
    let comment: NSColor
    let function: NSColor
    let type: NSColor
  }

  private static let stringExpression = try! NSRegularExpression(
    pattern: #"\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*'|`(?:\\.|[^`\\])*`"#
  )
  private static let numberExpression = try! NSRegularExpression(
    pattern: #"\b(?:0[xX][0-9a-fA-F]+|0[bB][01]+|\d+(?:\.\d+)?)\b"#
  )
  private static let functionExpression = try! NSRegularExpression(
    pattern: #"\b[A-Za-z_][A-Za-z0-9_]*(?=\s*\()"#
  )
  private static let typeExpression = try! NSRegularExpression(
    pattern: #"\b[A-Z][A-Za-z0-9_]*\b"#
  )
  private static let slashCommentExpression = try! NSRegularExpression(
    pattern: #"//[^\n]*|/\*[\s\S]*?\*/"#
  )
  private static let hashCommentExpression = try! NSRegularExpression(pattern: #"#[^\n]*"#)
  private static let markupCommentExpression = try! NSRegularExpression(
    pattern: #"<!--[\s\S]*?-->"#
  )
  private static let jsonKeyExpression = try! NSRegularExpression(
    pattern: #"\"(?:\\.|[^\"\\])*\"(?=\s*:)"#
  )
  private static let swiftKeywordExpression = keywordExpression(
    "actor|associatedtype|async|await|break|case|catch|class|continue|default|defer|deinit|do|else|enum|extension|fallthrough|false|fileprivate|for|func|guard|if|import|in|init|inout|internal|is|isolated|let|nil|nonisolated|open|operator|private|protocol|public|repeat|rethrows|return|self|some|static|struct|subscript|super|switch|throw|throws|true|try|typealias|var|where|while"
  )
  private static let javascriptKeywordExpression = keywordExpression(
    "as|async|await|break|case|catch|class|const|continue|debugger|default|delete|do|else|enum|export|extends|false|finally|for|from|function|get|if|implements|import|in|instanceof|interface|let|new|null|of|package|private|protected|public|return|satisfies|set|static|super|switch|this|throw|true|try|type|typeof|undefined|var|void|while|with|yield"
  )
  private static let pythonKeywordExpression = keywordExpression(
    "and|as|assert|async|await|break|case|class|continue|def|del|elif|else|except|False|finally|for|from|global|if|import|in|is|lambda|match|None|nonlocal|not|or|pass|raise|return|True|try|while|with|yield"
  )
  private static let shellKeywordExpression = keywordExpression(
    "case|do|done|elif|else|esac|export|fi|for|function|if|in|local|readonly|select|then|until|while"
  )
  private static let dataKeywordExpression = keywordExpression("false|null|true")

  static func background(isDark: Bool) -> NSColor {
    NSColor(hex: isDark ? 0x0D0D0D : 0xF7F7F7)
  }

  static func foreground(isDark: Bool) -> NSColor {
    colors(isDark: isDark).foreground
  }

  static func paragraphStyle() -> NSParagraphStyle {
    let style = NSMutableParagraphStyle()
    style.minimumLineHeight = lineHeight
    style.maximumLineHeight = lineHeight
    style.defaultTabInterval = font.maximumAdvancement.width * 2
    style.tabStops = []
    return style
  }

  static func baseAttributes(isDark: Bool) -> [NSAttributedString.Key: Any] {
    [
      .font: font,
      .foregroundColor: foreground(isDark: isDark),
      .paragraphStyle: paragraphStyle(),
    ]
  }

  static func attributedCode(_ text: String, path: String, isDark: Bool) -> NSAttributedString {
    let result = NSMutableAttributedString(
      string: text,
      attributes: baseAttributes(isDark: isDark)
    )
    highlight(
      result, path: path, isDark: isDark, range: NSRange(location: 0, length: result.length))
    return result
  }

  static func highlight(
    _ storage: NSMutableAttributedString,
    path: String,
    isDark: Bool,
    range requestedRange: NSRange
  ) {
    guard storage.length <= maximumHighlightedCharacters, storage.length > 0 else { return }
    let range = NSIntersectionRange(requestedRange, NSRange(location: 0, length: storage.length))
    guard range.length > 0 else { return }
    let colors = colors(isDark: isDark)
    storage.setAttributes(baseAttributes(isDark: isDark), range: range)
    let value = storage.string
    let language = language(for: path)

    if let expression = keywordExpression(for: language) {
      apply(expression, color: colors.keyword, to: storage, value: value, range: range)
    }
    apply(numberExpression, color: colors.number, to: storage, value: value, range: range)
    apply(typeExpression, color: colors.type, to: storage, value: value, range: range)
    apply(functionExpression, color: colors.function, to: storage, value: value, range: range)
    apply(stringExpression, color: colors.string, to: storage, value: value, range: range)

    switch language {
    case .python, .shell, .data:
      apply(hashCommentExpression, color: colors.comment, to: storage, value: value, range: range)
    case .markup:
      apply(markupCommentExpression, color: colors.comment, to: storage, value: value, range: range)
    case .swift, .javascript, .generic:
      apply(slashCommentExpression, color: colors.comment, to: storage, value: value, range: range)
    }
    if language == .data {
      apply(jsonKeyExpression, color: colors.function, to: storage, value: value, range: range)
    }
  }

  private static func colors(isDark: Bool) -> Colors {
    if isDark {
      return Colors(
        foreground: NSColor(hex: 0xD6DEEB),
        keyword: NSColor(hex: 0xC792EA),
        string: NSColor(hex: 0xECC48D),
        number: NSColor(hex: 0xF78C6C),
        comment: NSColor(hex: 0x637777),
        function: NSColor(hex: 0x82AAFF),
        type: NSColor(hex: 0x7FDBCA)
      )
    }
    return Colors(
      foreground: NSColor(hex: 0x242424),
      keyword: NSColor(hex: 0x7C3AED),
      string: NSColor(hex: 0x9A6700),
      number: NSColor(hex: 0xB42318),
      comment: NSColor(hex: 0x6A737D),
      function: NSColor(hex: 0x2457A6),
      type: NSColor(hex: 0x0F766E)
    )
  }

  private static func language(for path: String) -> Language {
    switch URL(fileURLWithPath: path).pathExtension.lowercased() {
    case "swift": .swift
    case "js", "jsx", "ts", "tsx", "mjs", "cjs": .javascript
    case "py", "pyi": .python
    case "sh", "zsh", "bash", "fish": .shell
    case "json", "jsonc", "yaml", "yml", "toml": .data
    case "html", "htm", "xml", "svg", "md", "mdx": .markup
    default: .generic
    }
  }

  private static func keywordExpression(for language: Language) -> NSRegularExpression? {
    switch language {
    case .swift: return swiftKeywordExpression
    case .javascript: return javascriptKeywordExpression
    case .python: return pythonKeywordExpression
    case .shell: return shellKeywordExpression
    case .data: return dataKeywordExpression
    case .markup, .generic:
      return nil
    }
  }

  private static func keywordExpression(_ words: String) -> NSRegularExpression {
    try! NSRegularExpression(pattern: "\\b(?:\(words))\\b")
  }

  private static func apply(
    _ expression: NSRegularExpression,
    color: NSColor,
    to storage: NSMutableAttributedString,
    value: String,
    range: NSRange
  ) {
    expression.enumerateMatches(in: value, range: range) { match, _, _ in
      guard let match else { return }
      storage.addAttribute(.foregroundColor, value: color, range: match.range)
    }
  }
}

struct NativeCodeTextView: NSViewRepresentable {
  @Binding var text: String
  let path: String
  let isDark: Bool
  let wrapsLines: Bool

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  func makeNSView(context: Context) -> TextSurfaceContainerView {
    let scrollView = NSScrollView()
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.drawsBackground = true
    scrollView.contentView.drawsBackground = true

    let storage = NSTextStorage()
    let layoutManager = NSLayoutManager()
    let textContainer = NSTextContainer(
      size: NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude)
    )
    storage.addLayoutManager(layoutManager)
    layoutManager.addTextContainer(textContainer)
    let textView = NSTextView(
      frame: NSRect(x: 0, y: 0, width: 100, height: 100),
      textContainer: textContainer
    )
    textView.delegate = context.coordinator
    textView.textStorage?.delegate = context.coordinator
    textView.isEditable = true
    textView.isSelectable = true
    textView.isRichText = false
    textView.isVerticallyResizable = true
    textView.allowsUndo = true
    textView.usesFindBar = true
    textView.isIncrementalSearchingEnabled = true
    textView.isAutomaticQuoteSubstitutionEnabled = false
    textView.isAutomaticDashSubstitutionEnabled = false
    textView.isAutomaticTextReplacementEnabled = false
    textView.isAutomaticSpellingCorrectionEnabled = false
    textView.textContainerInset = NSSize(width: 10, height: 10)
    scrollView.documentView = textView

    let lineNumbers = CodeLineNumberView(scrollView: scrollView, textView: textView)
    context.coordinator.textView = textView
    context.coordinator.lineNumbers = lineNumbers
    configure(scrollView, textView: textView)
    context.coordinator.apply(text, to: textView)
    return TextSurfaceContainerView(scrollView: scrollView, lineNumberView: lineNumbers)
  }

  func updateNSView(_ container: TextSurfaceContainerView, context: Context) {
    let scrollView = container.scrollView
    guard let textView = scrollView.documentView as? NSTextView else { return }
    let themeChanged = context.coordinator.parent.isDark != isDark
    let pathChanged = context.coordinator.parent.path != path
    context.coordinator.parent = self
    configure(scrollView, textView: textView)
    context.coordinator.lineNumbers?.needsDisplay = true
    if textView.string != text {
      context.coordinator.apply(text, to: textView)
    } else if themeChanged || pathChanged {
      context.coordinator.rehighlight(textView)
    }
  }

  private func configure(_ scrollView: NSScrollView, textView: NSTextView) {
    let background = NativeCodeStyle.background(isDark: isDark)
    scrollView.backgroundColor = background
    scrollView.contentView.backgroundColor = background
    scrollView.hasHorizontalScroller = !wrapsLines
    textView.backgroundColor = background
    textView.insertionPointColor = NSColor(hex: isDark ? 0xC792EA : 0x6F42C1)
    textView.font = NativeCodeStyle.font
    textView.typingAttributes = NativeCodeStyle.baseAttributes(isDark: isDark)
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
  }

  @MainActor
  final class Coordinator: NSObject, NSTextViewDelegate,
    @preconcurrency NSTextStorageDelegate
  {
    var parent: NativeCodeTextView
    weak var textView: NSTextView?
    weak var lineNumbers: CodeLineNumberView?
    private var isApplyingValue = false
    private var pendingHighlightRange: NSRange?
    private var highlightScheduled = false

    init(_ parent: NativeCodeTextView) {
      self.parent = parent
    }

    func apply(_ value: String, to textView: NSTextView) {
      isApplyingValue = true
      textView.textStorage?.setAttributedString(
        NativeCodeStyle.attributedCode(value, path: parent.path, isDark: parent.isDark)
      )
      isApplyingValue = false
      textView.typingAttributes = NativeCodeStyle.baseAttributes(isDark: parent.isDark)
      textView.undoManager?.removeAllActions()
      refreshDisplay(of: textView)
      lineNumbers?.needsDisplay = true
    }

    func rehighlight(_ textView: NSTextView) {
      guard let storage = textView.textStorage else { return }
      let selections = textView.selectedRanges
      isApplyingValue = true
      storage.setAttributedString(
        NativeCodeStyle.attributedCode(storage.string, path: parent.path, isDark: parent.isDark)
      )
      isApplyingValue = false
      textView.selectedRanges = selections
      textView.typingAttributes = NativeCodeStyle.baseAttributes(isDark: parent.isDark)
      refreshDisplay(of: textView)
      lineNumbers?.needsDisplay = true
    }

    func textDidChange(_ notification: Notification) {
      guard !isApplyingValue, let textView = notification.object as? NSTextView else { return }
      parent.text = textView.string
      lineNumbers?.needsDisplay = true
    }

    func textViewDidChangeSelection(_ notification: Notification) {
      guard let textView = notification.object as? NSTextView else { return }
      let value = textView.string as NSString
      let location = min(textView.selectedRange().location, value.length)
      lineNumbers?.selectedLineRange = value.lineRange(for: NSRange(location: location, length: 0))
    }

    func textStorage(
      _ textStorage: NSTextStorage,
      didProcessEditing editedMask: NSTextStorageEditActions,
      range editedRange: NSRange,
      changeInLength delta: Int
    ) {
      guard !isApplyingValue, editedMask.contains(.editedCharacters) else { return }
      let value = textStorage.string as NSString
      let location = min(editedRange.location, value.length)
      let length = min(max(editedRange.length, 1), max(0, value.length - location))
      let lineRange = value.lineRange(for: NSRange(location: location, length: length))
      pendingHighlightRange = pendingHighlightRange.map { NSUnionRange($0, lineRange) } ?? lineRange
      scheduleHighlight(textStorage)
    }

    private func scheduleHighlight(_ textStorage: NSTextStorage) {
      guard !highlightScheduled else { return }
      highlightScheduled = true
      DispatchQueue.main.async { [weak self, weak textStorage] in
        guard let self, let textStorage else { return }
        highlightScheduled = false
        guard let range = pendingHighlightRange else { return }
        pendingHighlightRange = nil
        isApplyingValue = true
        NativeCodeStyle.highlight(
          textStorage,
          path: parent.path,
          isDark: parent.isDark,
          range: range
        )
        isApplyingValue = false
        if let textView {
          refreshDisplay(of: textView)
        }
      }
    }

    private func refreshDisplay(of textView: NSTextView) {
      if let manager = textView.layoutManager, let container = textView.textContainer {
        manager.ensureLayout(for: container)
      }
      textView.needsDisplay = true
      textView.layer?.setNeedsDisplay()
    }
  }
}

@MainActor
final class TextSurfaceContainerView: NSView {
  let scrollView: NSScrollView
  private let lineNumberView: CodeLineNumberView?
  private var alignedInitialClip = false

  init(scrollView: NSScrollView, lineNumberView: CodeLineNumberView? = nil) {
    self.scrollView = scrollView
    self.lineNumberView = lineNumberView
    super.init(frame: .zero)
    wantsLayer = true
    scrollView.wantsLayer = true
    scrollView.contentView.wantsLayer = true
    if let lineNumberView {
      lineNumberView.wantsLayer = true
      lineNumberView.layer?.masksToBounds = true
      addSubview(lineNumberView)
    }
    addSubview(scrollView)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override var intrinsicContentSize: NSSize {
    NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
  }

  override func layout() {
    super.layout()
    let gutterWidth = lineNumberView == nil ? 0 : CodeLineNumberView.width
    lineNumberView?.frame = NSRect(x: 0, y: 0, width: gutterWidth, height: bounds.height)
    lineNumberView?.needsDisplay = true
    scrollView.frame = NSRect(
      x: gutterWidth,
      y: 0,
      width: max(0, bounds.width - gutterWidth),
      height: bounds.height
    )
    scrollView.tile()
    Self.fitDocument(in: scrollView)
    if !alignedInitialClip, bounds.width > 0, bounds.height > 0 {
      alignedInitialClip = true
      scrollView.contentView.scroll(to: .zero)
      scrollView.reflectScrolledClipView(scrollView.contentView)
    }
  }

  static func fitDocument(in scrollView: NSScrollView) {
    guard let textView = scrollView.documentView as? NSTextView else { return }
    let contentSize = scrollView.contentSize
    (textView.layoutManager as? ViewportWidthAwareLayout)?.minimumRowWidth = contentSize.width
    var frame = textView.frame
    if textView.textContainer?.widthTracksTextView == true {
      frame.size.width = contentSize.width
    } else {
      frame.size.width = max(frame.width, contentSize.width)
    }
    frame.size.height = max(frame.height, contentSize.height)
    if frame != textView.frame { textView.frame = frame }
  }
}

@MainActor
final class CodeLineNumberView: NSView {
  static let width: CGFloat = 52

  private weak var scrollView: NSScrollView?
  weak var textView: NSTextView?
  var selectedLineRange = NSRange(location: NSNotFound, length: 0) {
    didSet { needsDisplay = true }
  }

  init(scrollView: NSScrollView, textView: NSTextView) {
    self.scrollView = scrollView
    self.textView = textView
    super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 0))
    scrollView.contentView.postsBoundsChangedNotifications = true
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(redraw),
      name: NSView.boundsDidChangeNotification,
      object: scrollView.contentView
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(redraw),
      name: NSText.didChangeNotification,
      object: textView
    )
  }

  @available(*, unavailable)
  required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  deinit { NotificationCenter.default.removeObserver(self) }

  override var isFlipped: Bool { true }

  override func draw(_ rect: NSRect) {
    guard let textView, let layoutManager = textView.layoutManager,
      let textContainer = textView.textContainer, let scrollView
    else { return }
    let isDark = textView.backgroundColor.brightnessComponent < 0.5
    NativeCodeStyle.background(isDark: isDark).setFill()
    rect.fill()
    NSColor(hex: isDark ? 0x242424 : 0xE2E2E2).setFill()
    NSRect(x: bounds.maxX - 1, y: rect.minY, width: 1, height: rect.height).fill()

    let visibleRect = scrollView.contentView.bounds
    let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
    let value = textView.string as NSString
    let characterRange = layoutManager.characterRange(
      forGlyphRange: glyphRange, actualGlyphRange: nil)
    let lineStart = value.lineRange(for: NSRange(location: characterRange.location, length: 0))
      .location
    var lineNumber = 1
    if lineStart > 0 {
      lineNumber += value.substring(to: lineStart).reduce(into: 0) { count, character in
        if character == "\n" { count += 1 }
      }
    }
    let attributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
      .foregroundColor: NSColor(hex: isDark ? 0x637777 : 0x8A8A8A),
    ]
    let selectedAttributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
      .foregroundColor: NSColor(hex: isDark ? 0xD6DEEB : 0x242424),
    ]

    layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) {
      _, usedRect, _, lineGlyphRange, _ in
      let characterIndex = layoutManager.characterIndexForGlyph(at: lineGlyphRange.location)
      let isLineStart = characterIndex == 0 || value.character(at: characterIndex - 1) == 10
      guard isLineStart else { return }
      let label = "\(lineNumber)" as NSString
      let selected = NSLocationInRange(characterIndex, self.selectedLineRange)
      let labelAttributes = selected ? selectedAttributes : attributes
      let size = label.size(withAttributes: labelAttributes)
      let y = usedRect.minY + textView.textContainerOrigin.y - visibleRect.minY
      label.draw(
        at: NSPoint(x: Self.width - size.width - 10, y: y + 2),
        withAttributes: labelAttributes
      )
      lineNumber += 1
    }
  }

  @objc private func redraw() { needsDisplay = true }
}

extension NSColor {
  fileprivate var brightnessComponent: CGFloat {
    usingColorSpace(.deviceRGB).map { ($0.redComponent + $0.greenComponent + $0.blueComponent) / 3 }
      ?? 0
  }
}
