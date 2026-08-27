import XCTest

@testable import Chat42

@MainActor
final class ConversationPersistenceTests: XCTestCase {

  func testRoundTripPreservesTheTranscript() throws {
    let conversation = Conversation(
      title: "Budget review",
      messages: [
        Message(role: .system, content: "You are terse."),
        Message(
          role: .user, content: "summarise",
          attachments: [MessageAttachment(id: UUID(), name: "spec.pdf", type: .pdf)],
          contextText: "[File: spec.pdf]\nBudget is 42."),
        Message(role: .assistant, content: "Budget is 42."),
      ],
      modelName: "llama3.2:latest",
      backend: .ollama
    )

    let data = try JSONEncoder().encode([ConversationDTO(from: conversation)])
    let restored = try JSONDecoder().decode([ConversationDTO].self, from: data)
      .map { $0.toConversation() }

    XCTAssertEqual(restored.count, 1)
    let round = try XCTUnwrap(restored.first)
    XCTAssertEqual(round.title, "Budget review")
    XCTAssertEqual(round.backend, .ollama)
    XCTAssertEqual(round.modelName, "llama3.2:latest")
    XCTAssertEqual(round.messages.count, 3)
    XCTAssertEqual(round.messages[1].attachments.first?.name, "spec.pdf")
    XCTAssertEqual(round.messages[1].contextText, "[File: spec.pdf]\nBudget is 42.")
  }

  /// Image bytes the app owns are referenced by filename and must survive; user
  /// attachment bytes deliberately do not.
  func testGeneratedImageReferenceSurvives() throws {
    let conversation = Conversation(
      messages: [
        Message(
          role: .assistant, content: "",
          attachments: [
            MessageAttachment(
              id: UUID(), name: "a-cat.png", type: .image, storedFilename: "abc.png")
          ])
      ])
    let data = try JSONEncoder().encode([ConversationDTO(from: conversation)])
    let restored = try JSONDecoder().decode([ConversationDTO].self, from: data)
      .map { $0.toConversation() }
    XCTAssertEqual(restored.first?.messages.first?.attachments.first?.storedFilename, "abc.png")
  }

  /// Conversations written by older builds must still load — the app reads this
  /// file on every launch and a decode failure reads to the user as "everything is
  /// gone".
  func testLegacyConversationWithoutNewFieldsStillDecodes() throws {
    let legacy = """
      [{
        "id": "\(UUID().uuidString)",
        "title": "Old chat",
        "modelName": "mistral",
        "backend": "Ollama",
        "createdAt": 745200000,
        "updatedAt": 745200000,
        "messages": [{
          "id": "\(UUID().uuidString)",
          "role": "user",
          "content": "hello",
          "timestamp": 745200000
        }]
      }]
      """

    let restored = try JSONDecoder().decode([ConversationDTO].self, from: Data(legacy.utf8))
      .map { $0.toConversation() }

    let message = try XCTUnwrap(restored.first?.messages.first)
    XCTAssertEqual(message.content, "hello")
    XCTAssertEqual(message.contextText, "")
    XCTAssertFalse(message.isError)
    XCTAssertTrue(message.attachments.isEmpty)
  }

  func testUntitledConversationFallsBackToALocalizedName() {
    let conversation = Conversation(title: "")
    XCTAssertFalse(conversation.displayTitle.isEmpty)
  }

  func testMessageContextContentJoinsAttachmentTextAndTypedText() {
    let message = Message(role: .user, content: "typed", contextText: "doc")
    XCTAssertEqual(message.contextContent, "doc\n\ntyped")

    XCTAssertEqual(Message(role: .user, content: "typed").contextContent, "typed")
    XCTAssertEqual(
      Message(role: .user, content: "", contextText: "doc").contextContent, "doc")
  }

  func testSegmentCacheReturnsFreshResultsWhenContentGrows() {
    let message = Message(role: .assistant, content: "one")
    XCTAssertEqual(message.segments.count, 1)

    message.content = "one\n```swift\nlet x = 1\n```"
    XCTAssertEqual(message.segments.count, 2)

    message.content = "one"
    XCTAssertEqual(message.segments.count, 1)
  }
}

final class ImageFilenameTests: XCTestCase {

  @MainActor
  func testFilenameIsDerivedFromThePrompt() {
    XCTAssertEqual(
      AppState.imageFilename(for: "A cat wearing a tiny hat indoors"),
      "a-cat-wearing-a-tiny.png")
  }

  @MainActor
  func testPunctuationIsStripped() {
    XCTAssertEqual(AppState.imageFilename(for: "Hello, world!"), "hello-world.png")
  }

  @MainActor
  func testUnusablePromptFallsBackToADefaultName() {
    XCTAssertEqual(AppState.imageFilename(for: "!!! ???"), "image.png")
  }
}
