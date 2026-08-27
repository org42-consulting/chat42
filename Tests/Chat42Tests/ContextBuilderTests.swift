import XCTest

@testable import Chat42

@MainActor
final class ContextBuilderTests: XCTestCase {

  private func message(
    _ role: MessageRole, _ content: String, contextText: String = "",
    images: [String] = [], isError: Bool = false
  ) -> Message {
    Message(
      role: role, content: content, isError: isError,
      contextText: contextText, imageDataURIs: images)
  }

  /// Roughly four characters per token, so 400 characters ≈ 100 tokens.
  private func filler(_ characters: Int) -> String {
    String(repeating: "a", count: characters)
  }

  // MARK: - Filtering

  func testStreamingPlaceholderIsExcluded() {
    let placeholder = message(.assistant, "")
    let built = ContextBuilder.build(
      from: [message(.user, "hi"), placeholder],
      excluding: placeholder, tokenLimit: 8192)
    XCTAssertEqual(built.count, 1)
    XCTAssertEqual(built.first?.content, "hi")
  }

  func testErrorTextIsNeverReplayedToTheModel() {
    let built = ContextBuilder.build(
      from: [
        message(.user, "hi"),
        message(.assistant, "Error: gateway exploded", isError: true),
        message(.user, "still there?"),
      ],
      excluding: nil, tokenLimit: 8192)
    XCTAssertEqual(built.map(\.content), ["hi", "still there?"])
  }

  func testEmptyAssistantTurnsAreDropped() {
    let built = ContextBuilder.build(
      from: [message(.user, "hi"), message(.assistant, ""), message(.user, "again")],
      excluding: nil, tokenLimit: 8192)
    XCTAssertEqual(built.map(\.content), ["hi", "again"])
  }

  // MARK: - Attachment context

  /// The regression this exists to prevent: attach a document, ask a follow-up, and
  /// the document is no longer in the request.
  func testAttachmentTextSurvivesLaterTurns() {
    let built = ContextBuilder.build(
      from: [
        message(.user, "summarise this", contextText: "[File: spec.pdf]\nBudget is 42."),
        message(.assistant, "It says the budget is 42."),
        message(.user, "what was the budget again?"),
      ],
      excluding: nil, tokenLimit: 8192)

    XCTAssertEqual(built.count, 3)
    XCTAssertTrue(built[0].content.contains("Budget is 42."))
    XCTAssertTrue(built[0].content.contains("summarise this"))
  }

  func testAttachmentOnlyTurnSendsJustTheDocument() {
    let built = ContextBuilder.build(
      from: [message(.user, "", contextText: "[File: a.txt]\nbody")],
      excluding: nil, tokenLimit: 8192)
    XCTAssertEqual(built.first?.content, "[File: a.txt]\nbody")
  }

  func testImagesRideAlongWithTheirOwnTurn() {
    let built = ContextBuilder.build(
      from: [
        message(.user, "what is this?", images: ["data:image/png;base64,AAA"]),
        message(.assistant, "a cat"),
        message(.user, "and now?"),
      ],
      excluding: nil, tokenLimit: 8192)
    XCTAssertEqual(built[0].images, ["data:image/png;base64,AAA"])
    XCTAssertNil(built[2].images)
  }

  // MARK: - Trimming

  func testOldestTurnsAreDroppedFirst() {
    let built = ContextBuilder.build(
      from: [
        message(.user, filler(400)),  // ~100 tokens
        message(.assistant, filler(400)),
        message(.user, "newest"),
      ],
      excluding: nil, tokenLimit: 150)

    XCTAssertEqual(built.last?.content, "newest")
    XCTAssertLessThan(built.count, 3)
  }

  func testSystemPromptIsNeverTrimmed() {
    let built = ContextBuilder.build(
      from: [
        message(.system, "You are terse."),
        message(.user, filler(4000)),
        message(.user, "newest"),
      ],
      excluding: nil, tokenLimit: 100)

    XCTAssertEqual(built.first?.role, .system)
    XCTAssertEqual(built.first?.content, "You are terse.")
  }

  /// Trimming down to an empty request would send the model no question at all.
  func testNewestTurnSurvivesEvenWhenItAloneExceedsTheBudget() {
    let built = ContextBuilder.build(
      from: [message(.user, filler(40_000))],
      excluding: nil, tokenLimit: 100)
    XCTAssertEqual(built.count, 1)
  }

  func testEverythingFitsUnderAGenerousBudget() {
    let messages = (0..<10).map { message(.user, "turn \($0)") }
    let built = ContextBuilder.build(from: messages, excluding: nil, tokenLimit: 8192)
    XCTAssertEqual(built.count, 10)
  }

  func testChronologicalOrderIsPreservedAfterTrimming() {
    let built = ContextBuilder.build(
      from: [
        message(.system, "sys"),
        message(.user, "one"),
        message(.assistant, "two"),
        message(.user, "three"),
      ],
      excluding: nil, tokenLimit: 8192)
    XCTAssertEqual(built.map(\.content), ["sys", "one", "two", "three"])
  }
}
