import Foundation
import PDFKit
import UniformTypeIdentifiers

enum AttachmentProcessingError: LocalizedError {
  case pdfExtractionFailed(String)
  case unreadable(String)
  case unsupportedType(String)

  var errorDescription: String? {
    switch self {
    case .pdfExtractionFailed(let name): return "Could not extract text from \(name)"
    case .unreadable(let name): return "Could not read \(name)"
    case .unsupportedType(let name): return "Unsupported file type: \(name)"
    }
  }
}

struct AttachmentProcessor {

  static func attachmentType(for url: URL) -> AttachmentType? {
    guard let uttype = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
    else { return nil }
    if uttype.conforms(to: .image) { return .image }
    if uttype.conforms(to: .pdf) { return .pdf }
    if uttype.conforms(to: .text) { return .text }
    return nil
  }

  static func makeAttachedFile(url: URL) throws -> AttachedFile {
    guard let type = attachmentType(for: url) else {
      throw AttachmentProcessingError.unsupportedType(url.lastPathComponent)
    }
    let data: Data
    do { data = try Data(contentsOf: url) } catch {
      throw AttachmentProcessingError.unreadable(url.lastPathComponent)
    }
    let uttype = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
    let mimeType = uttype?.preferredMIMEType ?? "application/octet-stream"
    return AttachedFile(
      url: url, name: url.lastPathComponent,
      type: type, data: data, mimeType: mimeType
    )
  }

  // Returns contextText (for text/PDF files) and imageDataURIs (for images).
  // contextText is prepended to the user message in the API payload only — not stored in Message.content.
  // imageDataURIs are "data:<mimeType>;base64,<encoded>" strings.
  static func process(_ attachments: [AttachedFile]) throws -> (contextText: String, imageDataURIs: [String]) {
    var blocks: [String] = []
    var imageDataURIs: [String] = []

    for file in attachments {
      switch file.type {
      case .text:
        let text = String(data: file.data, encoding: .utf8) ?? "<binary content>"
        blocks.append("[File: \(file.name)]\n\(text)\n---")

      case .pdf:
        guard let doc = PDFDocument(data: file.data) else {
          throw AttachmentProcessingError.pdfExtractionFailed(file.name)
        }
        let text = (0..<doc.pageCount)
          .compactMap { doc.page(at: $0)?.string }
          .joined(separator: "\n")
        blocks.append("[File: \(file.name)]\n\(text)\n---")

      case .image:
        imageDataURIs.append("data:\(file.mimeType);base64,\(file.data.base64EncodedString())")
      }
    }

    return (blocks.joined(separator: "\n\n"), imageDataURIs)
  }
}
