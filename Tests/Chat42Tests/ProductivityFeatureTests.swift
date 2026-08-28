import XCTest

@testable import Chat42

@MainActor
final class PinnedContextTests: XCTestCase {

  private func message(_ role: MessageRole, _ content: String) -> Message {
    Message(role: role, content: content)
  }

  private func pinned(_ name: String, _ text: String) -> PinnedDocument {
    PinnedDocument(name: name, text: text, byteCount: text.utf8.count)
  }

  func testPinnedDocumentsReachTheModel() {
    let built = ContextBuilder.build(
      from: [message(.user, "what is the deadline?")],
      pinned: [pinned("spec.md", "Deadline is 3 March.")],
      excluding: nil, tokenLimit: 8192)

    XCTAssertTrue(built.contains { $0.content.contains("Deadline is 3 March.") })
  }

  /// The point of pinning: unlike an attachment, it is present on every turn — and
  /// it survives specifically *because* trimming dropped the turns around it.
  func testPinnedDocumentsSurviveTrimming() {
    // Each turn is ~100 tokens, so 40 of them cannot fit a 400-token budget.
    let filler = String(repeating: "x", count: 400)
    let messages = (0..<20).flatMap {
      [message(.user, "\(filler) q\($0)"), message(.assistant, "\(filler) a\($0)")]
    }
    let built = ContextBuilder.build(
      from: messages,
      pinned: [pinned("spec.md", "Deadline is 3 March.")],
      excluding: nil, tokenLimit: 400)

    XCTAssertTrue(built.contains { $0.content.contains("Deadline is 3 March.") })
    // Turns were dropped; the pinned document was not.
    let turnsKept = built.filter { $0.role != .system }.count
    XCTAssertLessThan(turnsKept, messages.count)
  }

  func testPinnedBlockSitsAfterTheSystemPrompt() {
    let built = ContextBuilder.build(
      from: [message(.system, "Be terse."), message(.user, "hi")],
      pinned: [pinned("a.txt", "body")],
      excluding: nil, tokenLimit: 8192)

    XCTAssertEqual(built.first?.content, "Be terse.")
    XCTAssertTrue(built[1].content.contains("body"))
    XCTAssertEqual(built.last?.content, "hi")
  }

  func testNoPinnedDocumentsChangesNothing() {
    let messages = [message(.user, "hi")]
    let withNone = ContextBuilder.build(
      from: messages, pinned: [], excluding: nil, tokenLimit: 8192)
    XCTAssertEqual(withNone.map(\.content), ["hi"])
  }

  func testUsageReportsTrimmingOnlyWhenItHappens() {
    let small = Conversation(messages: [message(.user, "hi")])
    XCTAssertFalse(ContextBuilder.usage(for: small, tokenLimit: 8192).isTrimming)

    let big = Conversation(
      messages: (0..<50).map { message(.user, String(repeating: "x", count: 400) + "\($0)") })
    let usage = ContextBuilder.usage(for: big, tokenLimit: 200)
    XCTAssertTrue(usage.isTrimming)
    XCTAssertEqual(usage.limit, 200)
  }

  func testUsageCountsPinnedDocuments() {
    let conversation = Conversation(messages: [message(.user, "hi")])
    let before = ContextBuilder.usage(for: conversation, tokenLimit: 8192).used
    conversation.pinnedDocuments = [pinned("big.txt", String(repeating: "y", count: 4_000))]
    let after = ContextBuilder.usage(for: conversation, tokenLimit: 8192).used
    XCTAssertGreaterThan(after, before + 500)
  }
}

@MainActor
final class ConversationSearchTests: XCTestCase {

  private func conversation(title: String, said: [String]) -> Conversation {
    Conversation(
      title: title,
      messages: said.map { Message(role: .user, content: $0) })
  }

  func testMatchesOnTitle() {
    let conv = conversation(title: "Budget review", said: ["unrelated"])
    XCTAssertTrue(conv.matches("budget"))
  }

  /// The reason full-text search exists: finding a chat by something said in it.
  func testMatchesOnMessageBody() {
    let conv = conversation(title: "Untitled", said: ["the retry logic uses exponential backoff"])
    XCTAssertTrue(conv.matches("exponential"))
    XCTAssertNotNil(conv.snippet(matching: "exponential"))
  }

  func testDoesNotMatchUnrelatedText() {
    let conv = conversation(title: "Budget review", said: ["nothing to see"])
    XCTAssertFalse(conv.matches("kangaroo"))
    XCTAssertNil(conv.snippet(matching: "kangaroo"))
  }

  func testEmptyQueryMatchesEverything() {
    let conv = conversation(title: "Anything", said: ["x"])
    XCTAssertTrue(conv.matches(""))
    XCTAssertTrue(conv.matches("   "))
  }

  func testSnippetIsEllipsisedAroundTheHit() {
    let long = String(repeating: "a ", count: 80) + "needle " + String(repeating: "b ", count: 80)
    let conv = conversation(title: "t", said: [long])
    let snippet = try? XCTUnwrap(conv.snippet(matching: "needle"))
    XCTAssertTrue(snippet?.contains("needle") == true)
    XCTAssertTrue(snippet?.hasPrefix("…") == true)
    XCTAssertLessThan(snippet?.count ?? .max, 130)
  }

  /// System messages carry the preset's instructions, which would match almost
  /// anything and are not something the user "said".
  func testSystemMessagesAreNotSearched() {
    let conv = Conversation(
      title: "t",
      messages: [Message(role: .system, content: "You are a helpful kangaroo expert.")])
    XCTAssertFalse(conv.matches("kangaroo"))
  }
}

@MainActor
final class PromptPresetTests: XCTestCase {

  func testSummaryDescribesWhatIsPinned() {
    let pinned = PromptPreset(
      name: "Reviewer", systemPrompt: "…", backend: .ollama,
      modelName: "llama3.2", temperature: 0.2)
    XCTAssertTrue(pinned.summary.contains("Ollama"))
    XCTAssertTrue(pinned.summary.contains("llama3.2"))

    let loose = PromptPreset(name: "Tone", systemPrompt: "…")
    XCTAssertEqual(loose.summary, String(localized: "preset.uses_current"))
  }

  func testUnnamedPresetFallsBackToALocalizedLabel() {
    XCTAssertFalse(PromptPreset(name: "", systemPrompt: "x").displayName.isEmpty)
  }

  func testRoundTripsThroughJSON() throws {
    let original = PromptPreset(
      name: "Commit", systemPrompt: "Write a commit message.",
      backend: .gateway, modelName: "gpt-4o", temperature: 0.2)
    let data = try JSONEncoder().encode([original])
    let restored = try JSONDecoder().decode([PromptPreset].self, from: data)

    XCTAssertEqual(restored.first?.id, original.id)
    XCTAssertEqual(restored.first?.backend, .gateway)
    XCTAssertEqual(restored.first?.modelName, "gpt-4o")
    XCTAssertEqual(restored.first?.temperature, 0.2)
  }

  /// A preset written before backend/model/temperature were optional extras must
  /// still load rather than taking the whole list down with it.
  func testLegacyPresetWithoutOptionalFieldsDecodes() throws {
    let json = #"[{"id":"\#(UUID().uuidString)","name":"Old","systemPrompt":"hi"}]"#
    let restored = try JSONDecoder().decode([PromptPreset].self, from: Data(json.utf8))
    XCTAssertEqual(restored.first?.name, "Old")
    XCTAssertNil(restored.first?.backend)
    XCTAssertNil(restored.first?.temperature)
  }

  func testStartersAreUsable() {
    for preset in PromptPreset.starters {
      XCTAssertFalse(preset.name.isEmpty)
      XCTAssertFalse(preset.systemPrompt.isEmpty)
    }
  }
}

@MainActor
final class ModelRefTests: XCTestCase {

  func testLabelsAreReadable() {
    let ref = ModelRef(backend: .mlx, model: "mlx-community/Llama-3.2-3B-Instruct-4bit")
    XCTAssertEqual(ref.shortLabel, "Llama-3.2-3B-Instruct-4bit")
    XCTAssertEqual(ref.fullLabel, "MLX · Llama-3.2-3B-Instruct-4bit")
  }

  func testIdentityDistinguishesSameModelOnDifferentBackends() {
    let a = ModelRef(backend: .ollama, model: "llama3.2")
    let b = ModelRef(backend: .gateway, model: "llama3.2")
    XCTAssertNotEqual(a, b)
    XCTAssertNotEqual(a.id, b.id)
  }

  func testRoundTripsThroughJSON() throws {
    let ref = ModelRef(backend: .gateway, model: "gpt-4o")
    let restored = try JSONDecoder().decode(
      ModelRef.self, from: try JSONEncoder().encode(ref))
    XCTAssertEqual(restored, ref)
  }
}

@MainActor
final class ConversationOrderingTests: XCTestCase {

  /// The sidebar used to show insertion order, so a chat replied to minutes ago
  /// sank below ones abandoned weeks earlier.
  func testRecencyOrderingUsesUpdatedAt() {
    let old = Conversation(title: "old", updatedAt: Date(timeIntervalSince1970: 1_000))
    let recent = Conversation(title: "recent", updatedAt: Date(timeIntervalSince1970: 9_000))
    let middle = Conversation(title: "middle", updatedAt: Date(timeIntervalSince1970: 5_000))

    let ordered = Conversation.byRecency([old, recent, middle])

    XCTAssertEqual(ordered.map(\.title), ["recent", "middle", "old"])
  }

  func testComparisonMessagesShareAGroupId() {
    let groupId = UUID()
    let left = Message(
      role: .assistant, content: "a",
      modelRef: ModelRef(backend: .ollama, model: "x"), comparisonGroupId: groupId)
    let right = Message(
      role: .assistant, content: "b",
      modelRef: ModelRef(backend: .gateway, model: "y"), comparisonGroupId: groupId)

    XCTAssertEqual(left.comparisonGroupId, right.comparisonGroupId)
    XCTAssertNotEqual(left.modelRef, right.modelRef)
  }

  func testConversationRoundTripKeepsPresetPinsAndComparison() throws {
    let conversation = Conversation(
      title: "t",
      messages: [Message(role: .user, content: "hi")],
      presetId: UUID(),
      pinnedDocuments: [PinnedDocument(name: "a.txt", text: "body", byteCount: 4)]
    )
    conversation.compareWith = ModelRef(backend: .gateway, model: "gpt-4o")

    let data = try JSONEncoder().encode([ConversationDTO(from: conversation)])
    let restored = try JSONDecoder().decode([ConversationDTO].self, from: data)
      .map { $0.toConversation() }
    let round = try XCTUnwrap(restored.first)

    XCTAssertEqual(round.presetId, conversation.presetId)
    XCTAssertEqual(round.pinnedDocuments.first?.name, "a.txt")
    XCTAssertEqual(round.compareWith?.model, "gpt-4o")
  }
}
