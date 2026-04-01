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

    init(id: UUID = UUID(), role: MessageRole, content: String, isStreaming: Bool = false, timestamp: Date = .now) {
        self.id = id
        self.role = role
        self.content = content
        self.isStreaming = isStreaming
        self.timestamp = timestamp
    }

    static func == (lhs: Message, rhs: Message) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Codable support for persistence
struct MessageDTO: Codable {
    let id: UUID
    let role: MessageRole
    let content: String
    let timestamp: Date

    init(from message: Message) {
        id = message.id
        role = message.role
        content = message.content
        timestamp = message.timestamp
    }

    func toMessage() -> Message {
        Message(id: id, role: role, content: content, timestamp: timestamp)
    }
}
