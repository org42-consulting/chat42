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
  /// Locally generated failure text, not a real model turn. Shown in the transcript
  /// but excluded from the context sent on later turns.
  var isError: Bool

  /// Text extracted from this turn's attachments (plain-text and PDF contents).
  ///
  /// Kept off `content` so the bubble still shows only what the user typed, but
  /// replayed on every later turn. Without it, a follow-up question about an
  /// attached document reaches the model with the document missing — the file was
  /// only ever visible on the turn it was attached.
  var contextText: String

  /// Data URIs for images attached to this turn.
  ///
  /// In-memory only: unlike `contextText` these are never persisted, keeping the
  /// rule that user-attached image bytes do not reach disk. The practical effect is
  /// that image follow-ups work for the rest of the session but not across a
  /// relaunch, where the chips remain and the pixels are gone.
  var imageDataURIs: [String]

  init(
    id: UUID = UUID(), role: MessageRole, content: String, isStreaming: Bool = false,
    timestamp: Date = .now, attachments: [MessageAttachment] = [], isError: Bool = false,
    contextText: String = "", imageDataURIs: [String] = []
  ) {
    self.id = id
    self.role = role
    self.content = content
    self.isStreaming = isStreaming
    self.timestamp = timestamp
    self.attachments = attachments
    self.isError = isError
    self.contextText = contextText
    self.imageDataURIs = imageDataURIs
  }

  /// `content` split into prose and code blocks, with prose pre-rendered.
  ///
  /// Memoised on the message rather than recomputed in `body`: a streaming reply
  /// re-evaluates the bubble on every flush, and re-parsing the whole string each
  /// time made rendering cost grow with the square of the reply length.
  @ObservationIgnored private var segmentCache: (source: String, value: [MessageSegment])?

  var segments: [MessageSegment] {
    let source = content
    if let cache = segmentCache, cache.source == source { return cache.value }
    let parsed = MessageSegment.parse(source)
    segmentCache = (source, parsed)
    return parsed
  }

  /// What this message contributes to the model's context: the typed text with any
  /// attachment text prepended.
  var contextContent: String {
    guard !contextText.isEmpty else { return content }
    guard !content.isEmpty else { return contextText }
    return "\(contextText)\n\n\(content)"
  }

  static func == (lhs: Message, rhs: Message) -> Bool { lhs.id == rhs.id }
  func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct ChatMessage: Sendable {
  let role: MessageRole
  let content: String
  let images: [String]?  // data URI strings, e.g. "data:image/jpeg;base64,..."

  init(role: MessageRole, content: String, images: [String]? = nil) {
    self.role = role
    self.content = content
    self.images = images
  }
}

// MARK: - Codable support for persistence
struct MessageDTO: Codable {
  let id: UUID
  let role: MessageRole
  let content: String
  let timestamp: Date
  let attachments: [MessageAttachment]
  let isError: Bool
  let contextText: String

  init(message: Message) {
    id = message.id
    role = message.role
    content = message.content
    timestamp = message.timestamp
    attachments = message.attachments
    isError = message.isError
    contextText = message.contextText
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(UUID.self, forKey: .id)
    role = try c.decode(MessageRole.self, forKey: .role)
    content = try c.decode(String.self, forKey: .content)
    timestamp = try c.decode(Date.self, forKey: .timestamp)
    attachments = (try? c.decode([MessageAttachment].self, forKey: .attachments)) ?? []
    isError = (try? c.decode(Bool.self, forKey: .isError)) ?? false
    // Absent in conversations written before attachment text was replayed.
    contextText = (try? c.decode(String.self, forKey: .contextText)) ?? ""
  }

  enum CodingKeys: String, CodingKey {
    case id, role, content, timestamp, attachments, isError, contextText
  }

  func toMessage() -> Message {
    Message(
      id: id, role: role, content: content, timestamp: timestamp, attachments: attachments,
      isError: isError, contextText: contextText)
  }
}
