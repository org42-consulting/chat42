import Foundation

enum MessageRole: String, Codable, Hashable {
  case user
  case assistant
  case system
}

@Observable
final class Message: Identifiable, Hashable {
  let id: UUID
  var role: MessageRole
  var content: String
  var isStreaming: Bool
  let timestamp: Date
  var attachments: [MessageAttachment]

  init(
    id: UUID = UUID(), role: MessageRole, content: String, isStreaming: Bool = false,
    timestamp: Date = .now, attachments: [MessageAttachment] = []
  ) {
    self.id = id
    self.role = role
    self.content = content
    self.isStreaming = isStreaming
    self.timestamp = timestamp
    self.attachments = attachments
  }

  static func == (lhs: Message, rhs: Message) -> Bool { lhs.id == rhs.id }
  func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct ChatMessage: Sendable {
  let role: MessageRole
  let content: String
  let images: [String]? = nil  // data URI strings, e.g. "data:image/jpeg;base64,..."
}

// MARK: - Codable support for persistence
struct MessageDTO: Codable {
  let id: UUID
  let role: MessageRole
  let content: String
  let timestamp: Date
  let attachments: [MessageAttachment]

  init(message: Message) {
    id = message.id
    role = message.role
    content = message.content
    timestamp = message.timestamp
    attachments = message.attachments
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(UUID.self, forKey: .id)
    role = try c.decode(MessageRole.self, forKey: .role)
    content = try c.decode(String.self, forKey: .content)
    timestamp = try c.decode(Date.self, forKey: .timestamp)
    attachments = (try? c.decode([MessageAttachment].self, forKey: .attachments)) ?? []
  }

  enum CodingKeys: String, CodingKey {
    case id, role, content, timestamp, attachments
  }

  func toMessage() -> Message {
    Message(id: id, role: role, content: content, timestamp: timestamp, attachments: attachments)
  }
}
