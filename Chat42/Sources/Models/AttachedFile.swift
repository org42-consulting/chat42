import Foundation
import UniformTypeIdentifiers

enum AttachmentType: String, Codable, Hashable {
  case text, image, pdf

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
}

struct MessageAttachment: Codable, Identifiable, Hashable {
  let id: UUID
  let name: String
  let type: AttachmentType
}
