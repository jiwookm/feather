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
        .onAppear {
          appDelegate.configureProcessShutdown {
            try await model.terminateProcessesForQuit()
          }
        }
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
        .disabled(
          model.selectedWorktree == nil || model.selectedAuthoritativeRemoteWorkspace != nil
        )
        Button("Search Repository…") {
          NotificationCenter.default.post(name: .featherRepositorySearchRequested, object: nil)
        }
        .keyboardShortcut("f", modifiers: [.command, .shift])
        .disabled(
          model.selectedWorktree == nil || model.selectedAuthoritativeRemoteWorkspace != nil
        )
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
        if model.selectedRemoteWorkspace == nil {
          Button("Run Workspace Remotely…") { model.requestRunSelectedWorkspaceRemotely() }
            .disabled(!model.canRunSelectedWorkspaceRemotely)
        } else if model.selectedAuthoritativeRemoteWorkspace != nil {
          Button("Reconnect Remote Workspace") { model.reconnectSelectedRemoteWorkspace() }
            .disabled(!model.canReconnectSelectedRemoteWorkspace)
          Button("Return Workspace to This Mac…") {
            model.requestReturnSelectedRemoteWorkspace()
          }
          .disabled(!model.canReturnSelectedRemoteWorkspace)
        } else {
          Button("Clean Up Remote Copy…") {
            model.requestCleanupSelectedRemoteWorkspace()
          }
          .disabled(!model.canCleanupSelectedRemoteWorkspace)
        }
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

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private var workspaceKeyMonitor: Any?
  private let quitCoordinator = ApplicationQuitCoordinator()

  func configureProcessShutdown(
    _ shutdownHandler: @escaping ApplicationQuitCoordinator.ShutdownHandler
  ) {
    quitCoordinator.shutdownHandler = shutdownHandler
  }

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

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    quitCoordinator.requestTermination { shouldTerminate in
      sender.reply(toApplicationShouldTerminate: shouldTerminate)
    }
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    false
  }
}
