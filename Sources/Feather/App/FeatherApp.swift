import AppKit
import FeatherCore
import SwiftUI

@main
struct FeatherApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @StateObject private var model = AppModel()

  var body: some Scene {
    WindowGroup {
      RootView()
        .environmentObject(model)
        .preferredColorScheme(preferredColorScheme)
    }
    .windowStyle(.hiddenTitleBar)
    .defaultSize(width: 1280, height: 800)
    .commands {
      CommandGroup(replacing: .newItem) {
        Button("New Terminal…") {
          NotificationCenter.default.post(name: .featherNewTerminalRequested, object: nil)
        }
        .keyboardShortcut("t", modifiers: .command)
        .disabled(!model.canCreateTerminal || model.isBusy)
        Button("New Worktree") { model.createWorktree() }
          .keyboardShortcut("n", modifiers: [.command, .shift])
          .disabled(model.selectedRepository == nil || model.isBusy)
        Divider()
        Button("Add Project…") { model.chooseAndRegisterRepository() }
          .keyboardShortcut("o", modifiers: .command)
      }
      CommandGroup(after: .sidebar) {
        Button(model.sidebarVisible ? "Hide Sidebar" : "Show Sidebar") {
          model.toggleSidebar()
        }
        .keyboardShortcut("s", modifiers: .command)
        Button(model.inspectorVisible ? "Hide Inspector" : "Show Inspector") {
          model.toggleInspector()
        }
        .keyboardShortcut("e", modifiers: .command)
      }
      CommandMenu("Navigate") {
        Button("Quick Open…") {
          NotificationCenter.default.post(name: .featherQuickOpenRequested, object: nil)
        }
        .keyboardShortcut("p", modifiers: .command)
        .disabled(model.selectedWorktree == nil)
      }
      CommandGroup(replacing: .saveItem) {
        Button("Save File") {
          NotificationCenter.default.post(name: .featherSaveDocumentRequested, object: nil)
        }
        .keyboardShortcut("s", modifiers: [.command, .shift])
      }
      CommandMenu("Terminal") {
        Button("Close Active File, Pane, or Terminal") {
          NotificationCenter.default.post(name: .featherCloseContextRequested, object: nil)
        }
        .keyboardShortcut("w", modifiers: .command)
        Divider()
        Button("Split Right") { model.splitTerminal(.right) }
          .keyboardShortcut("d", modifiers: .command)
          .disabled(model.selectedTerminal == nil)
        Button("Split Down") { model.splitTerminal(.down) }
          .keyboardShortcut("d", modifiers: [.command, .shift])
          .disabled(model.selectedTerminal == nil)
        Divider()
        Button("Next Terminal Tab") { model.selectAdjacentTerminal() }
          .keyboardShortcut(.tab, modifiers: .control)
          .disabled(model.selectedWorktreeTerminals.count < 2)
        Button("Previous Terminal Tab") { model.selectAdjacentTerminal(reverse: true) }
          .keyboardShortcut(.tab, modifiers: [.control, .shift])
          .disabled(model.selectedWorktreeTerminals.count < 2)
        Divider()
        Button("Reveal Worktree in Finder") { model.revealSelectedWorktree() }
          .disabled(model.selectedWorktree == nil)
        Divider()
        Button("Refresh Worktrees") { model.refresh() }
          .keyboardShortcut("r", modifiers: .command)
      }
    }

    Settings {
      SettingsView(model: model)
        .preferredColorScheme(preferredColorScheme)
    }
  }

  private var preferredColorScheme: ColorScheme? {
    switch model.appearance {
    case .system: nil
    case .light: .light
    case .dark: .dark
    }
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
  private var workspaceKeyMonitor: Any?

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
    workspaceKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
      guard modifiers.contains(.command),
        modifiers.intersection([.control, .option, .shift]).isEmpty,
        let key = event.charactersIgnoringModifiers?.lowercased(),
        NSApp.keyWindow === FeatherWindow.workspace
      else { return event }

      let notification: Notification.Name
      switch key {
      case "w": notification = .featherCloseContextRequested
      case "s": notification = .featherToggleSidebarRequested
      case "e": notification = .featherToggleInspectorRequested
      case "p": notification = .featherQuickOpenRequested
      default: return event
      }
      NotificationCenter.default.post(name: notification, object: nil)
      return nil
    }
  }

  func applicationWillTerminate(_ notification: Notification) {
    if let workspaceKeyMonitor {
      NSEvent.removeMonitor(workspaceKeyMonitor)
    }
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    true
  }
}
