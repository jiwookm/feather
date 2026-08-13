import Foundation
import Testing

@testable import FeatherCore

struct GitStatusParserTests {
  @Test
  func parsesBranchOrdinaryRenameConflictAndUntrackedRecords() {
    let records = [
      "# branch.oid abc123",
      "# branch.head alpha",
      "# branch.upstream origin/alpha",
      "# branch.ab +2 -1",
      "1 M. N... 100644 100644 100644 abc def staged.swift",
      "1 .M N... 100644 100644 100644 abc def changed.swift",
      "2 R. N... 100644 100644 100644 abc def R100 renamed.swift",
      "old.swift",
      "u UU N... 100644 100644 100644 100644 abc def ghi conflict.swift",
      "? new file.swift",
    ]
    let data = Data((records.joined(separator: "\0") + "\0").utf8)

    let snapshot = GitStatusParser.parse(data)

    #expect(snapshot.branch == "alpha")
    #expect(snapshot.upstream == "origin/alpha")
    #expect(snapshot.ahead == 2)
    #expect(snapshot.behind == 1)
    #expect(snapshot.files.count == 5)
    #expect(snapshot.files[0].isStaged)
    #expect(snapshot.files[1].hasWorktreeChanges)
    #expect(snapshot.files[2].originalPath == "old.swift")
    #expect(snapshot.files[3].isConflicted)
    #expect(snapshot.files[4].isUntracked)
  }

  @Test
  func capsParsedFiles() {
    let data = Data("? a\0? b\0? c\0".utf8)
    let snapshot = GitStatusParser.parse(data, maximumFiles: 2)
    #expect(snapshot.files.map(\.path) == ["a", "b"])
    #expect(snapshot.isTruncated)
  }

  @Test
  func parsesTextBinaryAndRenamedNumStats() {
    let data = Data(
      ("3\t1\tSources/App.swift\0"
        + "-\t-\tAssets/Icon.png\0"
        + "2\t4\t\0Sources/Old.swift\0Sources/New.swift\0").utf8
    )

    let stats = GitNumStatParser.parse(data)

    #expect(
      stats == [
        GitLineStat(path: "Sources/App.swift", additions: 3, deletions: 1),
        GitLineStat(path: "Assets/Icon.png", additions: nil, deletions: nil),
        GitLineStat(path: "Sources/New.swift", additions: 2, deletions: 4),
      ]
    )
  }
}
