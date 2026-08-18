import FeatherCore
import Foundation
import Testing

@testable import Feather

struct WorkspaceShortcutTests {
  @Test
  func commandDigitsMapToZeroBasedIndexesThroughNine() {
    #expect(WorkspaceShortcuts.index(for: "1") == 0)
    #expect(WorkspaceShortcuts.index(for: "5") == 4)
    #expect(WorkspaceShortcuts.index(for: "9") == 8)
    #expect(WorkspaceShortcuts.index(for: "0") == nil)
    #expect(WorkspaceShortcuts.index(for: "10") == nil)
    #expect(WorkspaceShortcuts.index(for: "a") == nil)
  }

  @Test
  func targetsFollowCrossProjectWorktreeOrderAndStopAtNine() {
    let firstRepository = RepositoryRecord(
      path: "/projects/first",
      displayName: "First"
    )
    let secondRepository = RepositoryRecord(
      path: "/projects/second",
      displayName: "Second"
    )
    let worktrees = [
      firstRepository.id: (1...4).map {
        GitWorktree(path: "/worktrees/first/\($0)", branch: "refs/heads/first-\($0)")
      },
      secondRepository.id: (1...7).map {
        GitWorktree(path: "/worktrees/second/\($0)", branch: "refs/heads/second-\($0)")
      },
    ]

    let targets = WorkspaceShortcuts.targets(
      repositories: [firstRepository, secondRepository],
      worktreesFor: { worktrees[$0.id] ?? [] }
    )

    #expect(targets.count == 9)
    #expect(
      targets.map(\.worktreeName) == [
        "first-1", "first-2", "first-3", "first-4",
        "second-1", "second-2", "second-3", "second-4", "second-5",
      ]
    )
    #expect(targets[4].repositoryID == secondRepository.id)
    #expect(targets.last?.worktreePath == "/worktrees/second/5")
  }
}
