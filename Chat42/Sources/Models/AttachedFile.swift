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

  init(id: UUID = UUID(), url: URL, name: String, type: AttachmentType, data: Data, mimeType: String) {
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
}
