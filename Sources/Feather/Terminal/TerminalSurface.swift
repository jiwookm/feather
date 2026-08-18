import AppKit
import SwiftUI

struct TerminalSurface: NSViewRepresentable {
  let handle: TerminalHandle

  func makeNSView(context: Context) -> FeatherGhosttyView {
    handle.view
  }

  func updateNSView(_ nsView: FeatherGhosttyView, context: Context) {
    if nsView.window?.firstResponder !== nsView {
      DispatchQueue.main.async { [weak nsView] in
        guard let nsView, let window = nsView.window else { return }
        window.makeFirstResponder(nsView)
      }
    }
  }
}
