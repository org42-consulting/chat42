import Foundation

enum AttachmentType: String, Codable, Hashable {
  case text = "text"
  case image = "image"
  case pdf = "pdf"

  var systemImage: String {
    switch self {
    case .text: return "doc.text"
    case .image: return "photo"
    case .pdf: return "doc.richtext"
    }
  }
}

struct AttachedFile: Identifiable {
  let id: UUID
  let url: URL
  let name: String
  let type: AttachmentType
  let data: Data
  let mimeType: String  // e.g. "image/jpeg"

  init(
    id: UUID = UUID(), url: URL, name: String, type: AttachmentType, data: Data, mimeType: String
  ) {
    self.id = id
    self.url = url
    self.name = name
    self.type = type
    self.data = data
    self.mimeType = mimeType
  }
}

struct MessageAttachment: Codable, Identifiable, Hashable {
  let id: UUID
  let name: String
  let type: AttachmentType
  /// Filename inside `ImageStore` for attachments whose bytes the app itself owns —
  /// model-generated images. Nil for user-attached files, whose bytes are still
  /// never written to disk.
  let storedFilename: String?

  init(id: UUID, name: String, type: AttachmentType, storedFilename: String? = nil) {
    self.id = id
    self.name = name
    self.type = type
    self.storedFilename = storedFilename
  }

  // Decoded leniently so conversations written before generated images existed
  // still load. Encoding stays synthesized.
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(UUID.self, forKey: .id)
    name = try c.decode(String.self, forKey: .name)
    type = try c.decode(AttachmentType.self, forKey: .type)
    storedFilename = try? c.decode(String.self, forKey: .storedFilename)
  }

  enum CodingKeys: String, CodingKey { case id, name, type, storedFilename }
}
