import XCTest

@testable import Chat42

/// Drives the real send pipeline against a recording HTTP server and inspects what
/// actually went over the wire.
///
/// The unit tests cover `ContextBuilder` in isolation; this covers the chain that
/// matters in practice — `sendMessage` → `appendUserMessage` → `ContextBuilder` →
/// `OllamaService` → HTTP body — which is where the "attachments are forgotten
/// after one turn" bug lived.
///
/// Skipped unless `CHAT42_MOCK_OLLAMA` names the base URL, so CI is unaffected:
///
///     ./scripts/mock-ollama.py --port 11500 --record /tmp/ollama-requests.jsonl &
///     CHAT42_MOCK_OLLAMA=http://127.0.0.1:11500 \
///     CHAT42_MOCK_RECORD=/tmp/ollama-requests.jsonl swift test
@MainActor
final class LivePipelineTests: XCTestCase {

  private var baseURL: String?
  private var recordPath: String!

  override func setUp() async throws {
    try await super.setUp()
    baseURL = ProcessInfo.processInfo.environment["CHAT42_MOCK_OLLAMA"]
    recordPath =
      ProcessInfo.processInfo.environment["CHAT42_MOCK_RECORD"] ?? "/tmp/ollama-requests.jsonl"
    try XCTSkipIf(baseURL == nil, "set CHAT42_MOCK_OLLAMA to run the live pipeline tests")
    // Each test reads only the requests it caused.
    FileManager.default.createFile(atPath: recordPath, contents: Data())
  }

  // MARK: - Helpers

  private func makeState() async -> AppState {
    let state = AppState()
    await state.ollamaService.updateBaseURL(baseURL!)
    state.activeBackend = .ollama
    await state.refreshOllamaModels()
    return state
  }

  private func textAttachment(_ name: String, _ body: String) -> AttachedFile {
    AttachedFile(
      url: URL(fileURLWithPath: "/tmp/\(name)"), name: name, type: .text,
      data: Data(body.utf8), mimeType: "text/plain")
  }

  private func waitUntilIdle(
    _ conversation: Conversation, timeout: TimeInterval = 20,
    file: StaticString = #filePath, line: UInt = #line
  ) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while conversation.isSending && Date() < deadline {
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTAssertFalse(
      conversation.isSending, "turn did not finish in \(timeout)s", file: file, line: line)
  }

  /// Every chat request the mock recorded, oldest first.
  private func recordedRequests() throws -> [[String: Any]] {
    let raw = try String(contentsOfFile: recordPath, encoding: .utf8)
    return raw.split(separator: "\n").compactMap { line in
      try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
    }
  }

  private func messageContents(_ request: [String: Any]) -> [String] {
    let messages = request["messages"] as? [[String: Any]] ?? []
    return messages.compactMap { $0["content"] as? String }
  }

  // MARK: - The regression this release exists to fix

  /// Attach a document, ask about it, then ask a follow-up. The document has to be
  /// in the *second* request too — previously it was only ever in the first.
  func testAttachedDocumentIsStillPresentOnTheFollowUpTurn() async throws {
    let state = await makeState()
    XCTAssertNotNil(state.selectedOllamaModel, "mock server should have advertised a model")

    let conversation = state.newConversation()
    state.sendMessage(
      "summarise this", attachments: [textAttachment("spec.txt", "The budget is 42 euros.")])
    try await waitUntilIdle(conversation)

    state.sendMessage("what was the budget again?")
    try await waitUntilIdle(conversation)

    let requests = try recordedRequests()
    XCTAssertEqual(requests.count, 2, "expected one request per turn")

    let first = messageContents(requests[0]).joined(separator: "\n")
    XCTAssertTrue(first.contains("The budget is 42 euros."), "turn 1 should carry the document")

    let second = messageContents(requests[1]).joined(separator: "\n")
    XCTAssertTrue(
      second.contains("The budget is 42 euros."),
      """
      turn 2 reached the model without the attached document. This is exactly the \
      bug the release claims to fix. Sent:
      \(second)
      """)
    XCTAssertTrue(second.contains("what was the budget again?"))
  }

  /// Pinned documents are meant to be in every request, not just the one they were
  /// added on.
  func testPinnedDocumentAppearsInEveryRequest() async throws {
    let state = await makeState()
    let conversation = state.newConversation()
    try state.pinDocument(textAttachment("contract.txt", "Party A is Acme Ltd."), to: conversation)

    state.sendMessage("who is party A?")
    try await waitUntilIdle(conversation)
    state.sendMessage("and party B?")
    try await waitUntilIdle(conversation)

    let requests = try recordedRequests()
    XCTAssertEqual(requests.count, 2)
    for (index, request) in requests.enumerated() {
      let body = messageContents(request).joined(separator: "\n")
      XCTAssertTrue(
        body.contains("Party A is Acme Ltd."), "pinned text missing from request \(index + 1)")
    }
  }

  /// `num_ctx` used to be hardcoded to 4096 regardless of the setting.
  func testContextLimitReachesTheRequestOptions() async throws {
    let state = await makeState()
    state.contextTokenLimit = 16384
    await state.ollamaService.updateContextTokenLimit(16384)

    let conversation = state.newConversation()
    state.sendMessage("hello")
    try await waitUntilIdle(conversation)

    let request = try XCTUnwrap(recordedRequests().first)
    let options = request["options"] as? [String: Any]
    XCTAssertEqual(options?["num_ctx"] as? Int, 16384)
  }

  /// Error turns are shown in the transcript but must never be replayed as if the
  /// model had said them.
  func testErrorTurnsAreNotReplayed() async throws {
    let state = await makeState()
    let conversation = state.newConversation()

    conversation.messages.append(Message(role: .user, content: "first"))
    conversation.messages.append(
      Message(role: .assistant, content: "Error: gateway exploded", isError: true))

    state.sendMessage("second")
    try await waitUntilIdle(conversation)

    let body = messageContents(try XCTUnwrap(recordedRequests().first)).joined(separator: "\n")
    XCTAssertFalse(body.contains("gateway exploded"))
    XCTAssertTrue(body.contains("second"))
  }

  /// A reply actually lands in the transcript — the streaming path completes and the
  /// message is marked finished.
  func testReplyIsStreamedIntoTheTranscript() async throws {
    let state = await makeState()
    let conversation = state.newConversation()

    state.sendMessage("hello")
    try await waitUntilIdle(conversation)

    let reply = try XCTUnwrap(conversation.messages.last)
    XCTAssertEqual(reply.role, .assistant)
    XCTAssertFalse(reply.isStreaming)
    XCTAssertFalse(reply.isError, "reply came back as an error: \(reply.content)")
    XCTAssertTrue(reply.content.contains("Recorded"), "got: \(reply.content)")
    XCTAssertEqual(reply.modelRef?.backend, .ollama)
  }
}
