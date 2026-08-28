import Foundation

/// A document kept in a conversation's context for every turn, rather than only the
/// turn it was attached on.
///
/// An attachment answers one question and then falls out of relevance; a pinned
/// document is the material the whole conversation is about — a spec, a source
/// file, a contract. Extracted text is stored, not the original bytes, matching how
/// attachments already work.
struct PinnedDocument: Identifiable, Codable, Hashable {
  let id: UUID
  var name: String
  var text: String
  /// Size of the source file, for display. The extracted text is usually smaller.
  var byteCount: Int

  init(id: UUID = UUID(), name: String, text: String, byteCount: Int) {
    self.id = id
    self.name = name
    self.text = text
    self.byteCount = byteCount
  }

  var formattedSize: String {
    ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
  }

  /// How the document is presented to the model.
  var contextBlock: String {
    "[Pinned file: \(name)]\n\(text)\n---"
  }
}

/// A specific model on a specific backend.
///
/// Used wherever a turn needs to name where it should run — comparison columns and
/// "retry with a different model" — instead of implicitly using whatever is
/// selected right now.
struct ModelRef: Codable, Hashable, Identifiable {
  var backend: AIBackend
  var model: String

  var id: String { "\(backend.rawValue)/\(model)" }

  /// Short form for a bubble caption, where the backend is usually obvious.
  var shortLabel: String {
    model.components(separatedBy: "/").last ?? model
  }

  var fullLabel: String {
    "\(backend.rawValue) · \(shortLabel)"
  }
}
