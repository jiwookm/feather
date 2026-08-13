import AppKit
import FeatherCore
import SwiftUI

enum AgentKind: String {
  case claude
  case codex

  init?(terminal: TerminalRecord) {
    switch terminal.title {
    case "Claude": self = .claude
    case "Codex": self = .codex
    default: return nil
    }
  }

  var title: String {
    switch self {
    case .claude: "Claude"
    case .codex: "Codex"
    }
  }

  fileprivate var fallbackSymbol: String {
    switch self {
    case .claude: "sparkles"
    case .codex: "chevron.left.forwardslash.chevron.right"
    }
  }
}

struct AgentIcon: View {
  @Environment(\.colorScheme) private var colorScheme
  let kind: AgentKind
  let size: CGFloat
  var tint: Color? = nil

  var body: some View {
    Group {
      if let image = AgentIconAssets.image(for: kind) {
        Image(nsImage: image)
          .renderingMode(kind == .codex ? .template : .original)
          .resizable()
      } else {
        Image(systemName: kind.fallbackSymbol)
          .resizable()
      }
    }
    .scaledToFit()
    .foregroundStyle(tint ?? FeatherPalette(colorScheme: colorScheme).secondaryText)
    .frame(width: size, height: size)
    .accessibilityLabel(kind.title)
  }
}

struct AgentSessionBadges: View {
  let kinds: [AgentKind]

  var body: some View {
    HStack(spacing: 3) {
      ForEach(Array(kinds.prefix(2).enumerated()), id: \.offset) { _, kind in
        AgentIcon(kind: kind, size: 14)
      }

      if kinds.count > 2 {
        Text("+")
          .font(.feather(size: 10, weight: .medium))
      }
    }
    .accessibilityElement(children: .combine)
    .help("\(kinds.count) active agent session\(kinds.count == 1 ? "" : "s")")
  }
}

@MainActor
private enum AgentIconAssets {
  static let claude = load("Claude")
  static let codex = load("OpenAI", template: true)

  static func image(for kind: AgentKind) -> NSImage? {
    switch kind {
    case .claude: claude
    case .codex: codex
    }
  }

  private static func load(_ name: String, template: Bool = false) -> NSImage? {
    guard
      let url = Bundle.main.url(
        forResource: name,
        withExtension: "png",
        subdirectory: "AgentIcons"
      ),
      let image = NSImage(contentsOf: url)
    else { return nil }
    image.isTemplate = template
    return image
  }
}
