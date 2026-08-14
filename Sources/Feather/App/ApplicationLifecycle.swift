import AppKit
import FeatherCore
import Foundation

struct FeatherProcessShutdown {
  typealias LocalServerTermination = @Sendable () async throws -> Void
  typealias RemoteServerTermination = @Sendable (SSHRemoteTerminal) async throws -> Void

  private struct RemoteServerKey: Hashable {
    let host: String
    let port: Int
    let configPath: String
    let socketName: String
  }

  let terminateLocalServer: LocalServerTermination?
  let terminateRemoteServer: RemoteServerTermination

  func terminateAll(terminals: [TerminalRecord]) async throws {
    var seenRemoteServers: Set<RemoteServerKey> = []
    var remoteServers: [SSHRemoteTerminal] = []
    for terminal in terminals {
      guard case .ssh(let remote) = terminal.executionTarget else { continue }
      let key = RemoteServerKey(
        host: remote.target.host,
        port: remote.target.port,
        configPath: remote.tmuxConfigPath,
        socketName: remote.tmuxSocketName
      )
      if seenRemoteServers.insert(key).inserted {
        remoteServers.append(remote)
      }
    }

    var remoteFailures: [String] = []
    for remote in remoteServers {
      do {
        try await terminateRemoteServer(remote)
      } catch {
        remoteFailures.append("\(remote.target.host): \(error.localizedDescription)")
      }
    }
    guard remoteFailures.isEmpty else {
      throw FeatherProcessShutdownError(remoteFailures: remoteFailures)
    }

    if let terminateLocalServer {
      try await terminateLocalServer()
    } else if terminals.contains(where: { $0.executionTarget == .local }) {
      throw FeatherError.tmuxUnavailable
    }
  }
}

struct FeatherProcessShutdownError: LocalizedError, Sendable {
  let remoteFailures: [String]

  var errorDescription: String? {
    "Feather could not stop every remote tmux server:\n\n"
      + remoteFailures.joined(separator: "\n")
  }
}

@MainActor
final class ApplicationQuitCoordinator {
  typealias Confirmation = () -> Bool
  typealias ErrorPresentation = (String) -> Void
  typealias ShutdownHandler = () async throws -> Void
  typealias TerminationReply = (Bool) -> Void

  var shutdownHandler: ShutdownHandler?

  private let confirm: Confirmation
  private let presentError: ErrorPresentation
  private var quitTask: Task<Void, Never>?

  init(
    confirm: @escaping Confirmation = { SystemQuitPrompt.confirmTermination() },
    presentError: @escaping ErrorPresentation = { SystemQuitPrompt.presentFailure($0) }
  ) {
    self.confirm = confirm
    self.presentError = presentError
  }

  func requestTermination(reply: @escaping TerminationReply) -> NSApplication.TerminateReply {
    guard quitTask == nil else { return .terminateLater }
    guard let shutdownHandler else {
      presentError("Feather could not prepare its managed processes for shutdown.")
      return .terminateCancel
    }
    guard confirm() else { return .terminateCancel }

    quitTask = Task {
      do {
        try await shutdownHandler()
        reply(true)
      } catch {
        presentError(error.localizedDescription)
        reply(false)
      }
      quitTask = nil
    }
    return .terminateLater
  }
}

@MainActor
private enum SystemQuitPrompt {
  static func confirmTermination() -> Bool {
    NSApp.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "Quit Feather and stop all processes?"
    alert.informativeText =
      "Feather will terminate every process in its local and remote tmux servers before quitting. "
      + "To keep them running, cancel and close the window instead."
    alert.addButton(withTitle: "Quit and Stop Everything")
    alert.buttons.first?.hasDestructiveAction = true
    alert.addButton(withTitle: "Cancel")
    return alert.runModal() == .alertFirstButtonReturn
  }

  static func presentFailure(_ message: String) {
    NSApp.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.alertStyle = .critical
    alert.messageText = "Feather did not quit"
    alert.informativeText = message
    alert.addButton(withTitle: "OK")
    alert.runModal()
  }
}
