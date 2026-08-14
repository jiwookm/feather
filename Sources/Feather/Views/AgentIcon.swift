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
          .interpolation(.high)
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
  let sessions: [AgentSessionPresentation]

  var body: some View {
    HStack(spacing: 3) {
      ForEach(sessions.prefix(2)) { session in
        AgentIcon(kind: session.kind, size: 14)
          .overlay(alignment: .bottomTrailing) {
            if session.state.showsNotificationBadge {
              TerminalRuntimeBadge(state: session.state, size: 6)
            }
          }
      }

      if sessions.count > 2 {
        Text("+")
          .font(.feather(size: 10, weight: .medium))
      }
    }
    .accessibilityElement(children: .combine)
    .help("\(sessions.count) agent session\(sessions.count == 1 ? "" : "s")")
  }
}

struct AgentSessionPresentation: Identifiable {
  let id: UUID
  let kind: AgentKind
  let state: TerminalRuntimeState
}

extension TerminalRuntimeState {
  var showsNotificationBadge: Bool {
    switch self {
    case .attention, .exited: true
    case .shell, .running: false
    }
  }
}

struct TerminalRuntimeBadge: View {
  @Environment(\.colorScheme) private var colorScheme
  let state: TerminalRuntimeState
  var size: CGFloat = 7

  private var palette: FeatherPalette { FeatherPalette(colorScheme: colorScheme) }

  @ViewBuilder
  var body: some View {
    if state.showsNotificationBadge {
      Circle()
        .fill(color)
        .frame(width: size, height: size)
        .overlay { Circle().stroke(palette.titlebar, lineWidth: 1) }
        .accessibilityLabel(label)
        .help(label)
    }
  }

  private var color: Color {
    switch state {
    case .attention: Color(hex: 0xF0A33A)
    case .exited: Color(hex: 0xD45555)
    case .shell, .running: .clear
    }
  }

  private var label: String {
    switch state {
    case .shell: "Shell ready"
    case .running: "Running"
    case .attention: "Attention requested"
    case .exited: "Exited"
    }
  }
}

@MainActor
private enum AgentIconAssets {
  static let claude = load("Claude", extension: "svg") ?? load("Claude", extension: "png")
  static let codex =
    load("OpenAI", extension: "svg", template: true)
    ?? load("OpenAI", extension: "png", template: true)

  static func image(for kind: AgentKind) -> NSImage? {
    switch kind {
    case .claude: claude
    case .codex: codex
    }
  }

  private static func load(
    _ name: String,
    extension fileExtension: String,
    template: Bool = false
  ) -> NSImage? {
    guard
      let url = Bundle.main.url(
        forResource: name,
        withExtension: fileExtension,
        subdirectory: "AgentIcons"
      ),
      let image = NSImage(contentsOf: url)
    else { return nil }
    image.isTemplate = template
    return image
  }
}
