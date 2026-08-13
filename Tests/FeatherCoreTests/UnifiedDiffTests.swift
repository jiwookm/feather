import Testing

@testable import FeatherCore

struct UnifiedDiffTests {
  @Test
  func parsesLineNumbersAndStatistics() {
    let patch = """
      diff --git a/sample.swift b/sample.swift
      --- a/sample.swift
      +++ b/sample.swift
      @@ -10,3 +10,4 @@
       let kept = true
      -let old = 1
      +let new = 2
      +let added = 3
       return kept
      """

    let document = UnifiedDiffDocument.parse(patch)

    #expect(document.additions == 2)
    #expect(document.deletions == 1)
    #expect(document.lines.first(where: { $0.kind == .deletion })?.oldLine == 11)
    #expect(document.lines.first(where: { $0.kind == .addition })?.newLine == 11)
    #expect(document.lines.last(where: { $0.kind == .context })?.newLine == 13)
  }

  @Test
  func alignsDeletionAndAdditionBlocksForSplitRendering() {
    let patch = """
      @@ -1,3 +1,4 @@
      -old one
      -old two
      +new one
      +new two
      +new three
       shared
      """

    let rows = UnifiedDiffDocument.parse(patch).splitRows
    let changedRows = rows.filter { $0.left?.kind == .deletion || $0.right?.kind == .addition }

    #expect(changedRows.count == 3)
    #expect(changedRows[0].left?.text == "old one")
    #expect(changedRows[0].right?.text == "new one")
    #expect(changedRows[2].left == nil)
    #expect(changedRows[2].right?.text == "new three")
  }

  @Test
  func leavesTheOppositeSideBlankForPureInsertions() {
    let patch = """
      @@ -1 +1,3 @@
       shared
      +added one
      +added two
      """

    let addedRows = UnifiedDiffDocument.parse(patch).splitRows.filter {
      $0.right?.kind == .addition
    }

    #expect(addedRows.count == 2)
    #expect(addedRows.allSatisfy { $0.left == nil })
  }
}
