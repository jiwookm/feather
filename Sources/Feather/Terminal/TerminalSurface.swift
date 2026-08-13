import AppKit
import GhosttyKit
import SwiftUI

struct TerminalSurface: NSViewRepresentable {
  let handle: TerminalHandle

  func makeNSView(context: Context) -> GhosttyTerminalView {
    handle.view
  }

  func updateNSView(_ nsView: GhosttyTerminalView, context: Context) {
    if nsView.window?.firstResponder !== nsView {
      DispatchQueue.main.async { [weak nsView] in
        guard let nsView, let window = nsView.window else { return }
        window.makeFirstResponder(nsView)
      }
    }
  }
}
