import Foundation

@Observable
final class Conversation: Identifiable, Hashable {
  let id: UUID
  var title: String
  var messages: [Message]
  var modelName: String
  var backend: AIBackend
  let createdAt: Date
  var updatedAt: Date

  /// Streaming state lives on the conversation, not on `AppState`, so a reply
  /// arriving in one chat does not disable the composer in every other chat.
  var isSending: Bool = false
  /// Image generation is a single slow request rather than a token stream, so the
  /// toolbar needs to say something different while it runs.
  var isGeneratingImage: Bool = false

  /// The preset this conversation was started from, so it can be shown and reused.
  var presetId: UUID?

  /// Documents kept in context for every turn. See `PinnedDocument`.
  var pinnedDocuments: [PinnedDocument] = []

  /// When set, each turn is also answered by this model and the two replies are
  /// rendered side by side.
  var compareWith: ModelRef?

  init(
    id: UUID = UUID(),
    title: String = "",
    messages: [Message] = [],
    modelName: String = "",
    backend: AIBackend = .ollama,
    createdAt: Date = .now,
    updatedAt: Date = .now,
    presetId: UUID? = nil,
    pinnedDocuments: [PinnedDocument] = []
  ) {
    self.id = id
    self.title = title
    self.messages = messages
    self.modelName = modelName
    self.backend = backend
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.presetId = presetId
    self.pinnedDocuments = pinnedDocuments
  }

  var lastMessage: Message? { messages.last }

  var displayTitle: String {
    title.isEmpty ? String(localized: "default.new_chat") : title
  }

  /// First match of `query` in the transcript, for the sidebar's result snippet.
  /// Returns nil when nothing matches.
  func snippet(matching query: String) -> String? {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    for message in messages where message.role != .system {
      guard
        let range = message.content.range(
          of: trimmed, options: [.caseInsensitive, .diacriticInsensitive])
      else { continue }
      // A little context either side, so the hit is legible rather than a bare word.
      let lower =
        message.content.index(
          range.lowerBound, offsetBy: -40,
          limitedBy: message.content.startIndex) ?? message.content.startIndex
      let upper =
        message.content.index(
          range.upperBound, offsetBy: 60,
          limitedBy: message.content.endIndex) ?? message.content.endIndex
      let fragment = message.content[lower..<upper]
        .replacingOccurrences(of: "\n", with: " ")
        .trimmingCharacters(in: .whitespaces)
      let prefix = lower == message.content.startIndex ? "" : "…"
      let suffix = upper == message.content.endIndex ? "" : "…"
      return prefix + fragment + suffix
    }
    return nil
  }

  /// True when the query matches the title or anything said in the conversation.
  func matches(_ query: String) -> Bool {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return true }
    if displayTitle.localizedCaseInsensitiveContains(trimmed) { return true }
    return snippet(matching: trimmed) != nil
  }

  static func == (lhs: Conversation, rhs: Conversation) -> Bool { lhs.id == rhs.id }
  func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

extension Conversation {
  /// Most recently active first.
  ///
  /// A free function rather than only a computed property on `AppState`, so the
  /// ordering can be exercised without constructing one — `AppState.init` reads the
  /// Keychain and the conversations file, which a unit test should not touch.
  static func byRecency(_ conversations: [Conversation]) -> [Conversation] {
    conversations.sorted { $0.updatedAt > $1.updatedAt }
  }
}

// MARK: - Persistence
struct ConversationDTO: Codable {
  let id: UUID
  let title: String
  let messages: [MessageDTO]
  let modelName: String
  let backend: AIBackend
  let createdAt: Date
  let updatedAt: Date
  let presetId: UUID?
  let pinnedDocuments: [PinnedDocument]
  let compareWith: ModelRef?

  init(from conv: Conversation) {
    id = conv.id
    title = conv.title
    messages = conv.messages.map { MessageDTO(message: $0) }
    modelName = conv.modelName
    backend = conv.backend
    createdAt = conv.createdAt
    updatedAt = conv.updatedAt
    presetId = conv.presetId
    pinnedDocuments = conv.pinnedDocuments
    compareWith = conv.compareWith
  }

  // Decoded leniently: conversations written before presets, pinned documents, or
  // comparison existed must still load.
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(UUID.self, forKey: .id)
    title = (try? c.decode(String.self, forKey: .title)) ?? ""
    messages = (try? c.decode([MessageDTO].self, forKey: .messages)) ?? []
    modelName = (try? c.decode(String.self, forKey: .modelName)) ?? ""
    backend = (try? c.decode(AIBackend.self, forKey: .backend)) ?? .ollama
    createdAt = (try? c.decode(Date.self, forKey: .createdAt)) ?? .now
    updatedAt = (try? c.decode(Date.self, forKey: .updatedAt)) ?? .now
    presetId = try? c.decode(UUID.self, forKey: .presetId)
    pinnedDocuments = (try? c.decode([PinnedDocument].self, forKey: .pinnedDocuments)) ?? []
    compareWith = try? c.decode(ModelRef.self, forKey: .compareWith)
  }

  enum CodingKeys: String, CodingKey {
    case id, title, messages, modelName, backend, createdAt, updatedAt
    case presetId, pinnedDocuments, compareWith
  }

  func toConversation() -> Conversation {
    let conversation = Conversation(
      id: id,
      title: title,
      messages: messages.map { $0.toMessage() },
      modelName: modelName,
      backend: backend,
      createdAt: createdAt,
      updatedAt: updatedAt,
      presetId: presetId,
      pinnedDocuments: pinnedDocuments
    )
    conversation.compareWith = compareWith
    return conversation
  }
}
