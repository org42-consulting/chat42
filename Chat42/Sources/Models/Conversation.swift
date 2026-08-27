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

  init(
    id: UUID = UUID(),
    title: String = "",
    messages: [Message] = [],
    modelName: String = "",
    backend: AIBackend = .ollama,
    createdAt: Date = .now,
    updatedAt: Date = .now
  ) {
    self.id = id
    self.title = title
    self.messages = messages
    self.modelName = modelName
    self.backend = backend
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  var lastMessage: Message? { messages.last }

  var displayTitle: String {
    title.isEmpty ? String(localized: "default.new_chat") : title
  }

  static func == (lhs: Conversation, rhs: Conversation) -> Bool { lhs.id == rhs.id }
  func hash(into hasher: inout Hasher) { hasher.combine(id) }
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

  init(from conv: Conversation) {
    id = conv.id
    title = conv.title
    messages = conv.messages.map { MessageDTO(message: $0) }
    modelName = conv.modelName
    backend = conv.backend
    createdAt = conv.createdAt
    updatedAt = conv.updatedAt
  }

  func toConversation() -> Conversation {
    Conversation(
      id: id,
      title: title,
      messages: messages.map { $0.toMessage() },
      modelName: modelName,
      backend: backend,
      createdAt: createdAt,
      updatedAt: updatedAt
    )
  }
}
