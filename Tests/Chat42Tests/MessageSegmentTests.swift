import XCTest

@testable import Chat42

final class MessageSegmentTests: XCTestCase {

  func testPlainProseIsOneTextPiece() {
    let pieces = MessageSegment.split("Hello there.\nSecond line.")
    XCTAssertEqual(pieces, [.text("Hello there.\nSecond line.")])
  }

  func testFencedBlockIsSplitOutWithLanguage() {
    let pieces = MessageSegment.split(
      """
      Before

      ```swift
      let x = 1
      ```

      After
      """)
    XCTAssertEqual(
      pieces,
      [
        .text("Before\n"),
        .code(language: "swift", body: "let x = 1"),
        .text("\nAfter"),
      ])
  }

  func testFenceWithoutLanguageTagHasNilLanguage() {
    let pieces = MessageSegment.split("```\nraw\n```")
    XCTAssertEqual(pieces, [.code(language: nil, body: "raw")])
  }

  /// A reply is rendered while it streams, so the closing fence has usually not
  /// arrived yet. The open block still has to render as code.
  func testUnterminatedFenceStillEmitsACodeBlock() {
    let pieces = MessageSegment.split("Here you go:\n```python\nprint(1)")
    XCTAssertEqual(
      pieces,
      [
        .text("Here you go:"),
        .code(language: "python", body: "print(1)"),
      ])
  }

  func testWhitespaceOnlyProseIsDropped() {
    let pieces = MessageSegment.split("   \n\n```js\na\n```\n   ")
    XCTAssertEqual(pieces, [.code(language: "js", body: "a")])
  }

  func testIndentedFenceIsRecognised() {
    let pieces = MessageSegment.split("  ```go\nx\n  ```")
    XCTAssertEqual(pieces, [.code(language: "go", body: "x")])
  }

  func testMultipleBlocksKeepOrder() {
    let pieces = MessageSegment.split("```a\n1\n```\nmid\n```b\n2\n```")
    XCTAssertEqual(
      pieces,
      [
        .code(language: "a", body: "1"),
        .text("mid"),
        .code(language: "b", body: "2"),
      ])
  }

  func testEmptyContentProducesNoPieces() {
    XCTAssertTrue(MessageSegment.split("").isEmpty)
  }

  /// Inline markdown is styled, and — unlike the previous line-by-line parse — the
  /// line breaks around it survive.
  func testAttributedRenderingPreservesNewlines() {
    let rendered = MessageSegment.attributed("first **bold**\nsecond")
    XCTAssertEqual(String(rendered.characters), "first bold\nsecond")
  }

  func testAttributedRenderingFallsBackOnMalformedMarkdown() {
    let rendered = MessageSegment.attributed("unclosed [link(")
    XCTAssertFalse(String(rendered.characters).isEmpty)
  }
}
