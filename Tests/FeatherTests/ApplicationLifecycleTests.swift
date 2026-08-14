import AppKit
import FeatherCore
import Foundation
import Testing

@testable import Feather

struct ApplicationLifecycleTests {
  @Test @MainActor
  func closingTheLastWindowKeepsFeatherRunning() {
    let delegate = AppDelegate()

    #expect(!delegate.applicationShouldTerminateAfterLastWindowClosed(.shared))
  }

  @Test @MainActor
  func cancellingQuitLeavesProcessesRunning() {
    var shutdownCalled = false
    let coordinator = ApplicationQuitCoordinator(
      confirm: { false },
      presentError: { _ in }
    )
    coordinator.shutdownHandler = { shutdownCalled = true }

    let response = coordinator.requestTermination { _ in
      Issue.record("A cancelled quit must not send an asynchronous termination reply")
    }

    #expect(response == .terminateCancel)
    #expect(!shutdownCalled)
  }

  @Test @MainActor
  func confirmedQuitWaitsForCleanupBeforeReplying() async {
    let events = EventRecorder()
    let reply = TerminationReplyProbe()
    let coordinator = ApplicationQuitCoordinator(
      confirm: { true },
      presentError: { Issue.record("Unexpected shutdown error: \($0)") }
    )
    coordinator.shutdownHandler = {
      await events.append("cleanup")
    }

    let response = coordinator.requestTermination { value in
      Task {
        await events.append("reply")
        reply.record(value)
      }
    }

    #expect(response == .terminateLater)
    #expect(await reply.wait())
    #expect(await events.values() == ["cleanup", "reply"])
  }

  @Test @MainActor
  func cleanupFailureCancelsTerminationAndExplainsWhy() async {
    let reply = TerminationReplyProbe()
    var presentedMessages: [String] = []
    let coordinator = ApplicationQuitCoordinator(
      confirm: { true },
      presentError: { presentedMessages.append($0) }
    )
    coordinator.shutdownHandler = { throw FixtureFailure.cleanup }

    let response = coordinator.requestTermination { reply.record($0) }

    #expect(response == .terminateLater)
    #expect(!(await reply.wait()))
    #expect(presentedMessages == [FixtureFailure.cleanup.localizedDescription])
  }

  @Test
  func shutdownStopsEachRemoteServerOnceBeforeTheLocalServer() async throws {
    let events = EventRecorder()
    let firstRemote = remote(host: "builder", configPath: "/srv/feather/tmux.conf")
    let secondRemote = remote(host: "runner", configPath: "/srv/other/tmux.conf")
    let shutdown = FeatherProcessShutdown(
      terminateLocalServer: { await events.append("local") },
      terminateRemoteServer: { remote in
        await events.append("remote:\(remote.target.host)")
      }
    )

    try await shutdown.terminateAll(
      terminals: [
        terminal(target: .local, sessionID: "local"),
        terminal(target: .ssh(firstRemote), sessionID: "remote-one"),
        terminal(target: .ssh(firstRemote), sessionID: "remote-two"),
        terminal(target: .ssh(secondRemote), sessionID: "remote-three"),
      ]
    )

    #expect(await events.values() == ["remote:builder", "remote:runner", "local"])
  }

  @Test
  func remoteCleanupFailureAttemptsEveryRemoteAndPreservesTheLocalServer() async {
    let events = EventRecorder()
    let shutdown = FeatherProcessShutdown(
      terminateLocalServer: { await events.append("local") },
      terminateRemoteServer: { remote in
        await events.append("remote:\(remote.target.host)")
        if remote.target.host == "broken" { throw FixtureFailure.cleanup }
      }
    )

    await #expect(throws: FeatherProcessShutdownError.self) {
      try await shutdown.terminateAll(
        terminals: [
          terminal(target: .ssh(remote(host: "broken")), sessionID: "broken"),
          terminal(target: .ssh(remote(host: "healthy")), sessionID: "healthy"),
          terminal(target: .local, sessionID: "local"),
        ]
      )
    }
    #expect(await events.values() == ["remote:broken", "remote:healthy"])
  }

  @Test
  func localTerminalsRequireAnAvailableTmuxBackend() async {
    let shutdown = FeatherProcessShutdown(
      terminateLocalServer: nil,
      terminateRemoteServer: { _ in }
    )

    await #expect(throws: FeatherError.tmuxUnavailable) {
      try await shutdown.terminateAll(
        terminals: [terminal(target: .local, sessionID: "local")]
      )
    }
  }

  private func terminal(
    target: TerminalExecutionTarget,
    sessionID: String
  ) -> TerminalRecord {
    TerminalRecord(
      repositoryID: UUID(),
      worktreePath: "/tmp/worktree",
      title: sessionID,
      order: 0,
      tmuxSessionID: sessionID,
      executionTarget: target
    )
  }

  private func remote(
    host: String,
    configPath: String = "/srv/feather/tmux.conf"
  ) -> SSHRemoteTerminal {
    SSHRemoteTerminal(
      target: SSHRemoteTarget(host: host, rootPath: "/srv/feather"),
      workingDirectory: "/srv/feather/worktree",
      tmuxConfigPath: configPath
    )
  }
}

private enum FixtureFailure: LocalizedError {
  case cleanup

  var errorDescription: String? { "fixture cleanup failed" }
}

private actor EventRecorder {
  private var recorded: [String] = []

  func append(_ event: String) {
    recorded.append(event)
  }

  func values() -> [String] {
    recorded
  }
}

@MainActor
private final class TerminationReplyProbe {
  private var value: Bool?
  private var continuation: CheckedContinuation<Bool, Never>?

  func record(_ value: Bool) {
    if let continuation {
      self.continuation = nil
      continuation.resume(returning: value)
    } else {
      self.value = value
    }
  }

  func wait() async -> Bool {
    if let value {
      self.value = nil
      return value
    }
    return await withCheckedContinuation { continuation = $0 }
  }
}
