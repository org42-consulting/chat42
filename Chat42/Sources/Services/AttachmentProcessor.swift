import Foundation
import PDFKit
import UniformTypeIdentifiers

enum AttachmentProcessingError: LocalizedError {
  case pdfExtractionFailed(String)
  case unreadable(String)
  case unsupportedType(String)
  case tooLarge(name: String, limit: Int)

  var errorDescription: String? {
    switch self {
    case .pdfExtractionFailed(let name):
      return String(format: String(localized: "error.attachment.pdf_failed"), name)
    case .unreadable(let name):
      return String(format: String(localized: "error.attachment.unreadable"), name)
    case .unsupportedType(let name):
      return String(format: String(localized: "error.attachment.unsupported"), name)
    case .tooLarge(let name, let limit):
      let formatted = ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file)
      return String(format: String(localized: "error.attachment.too_large"), name, formatted)
    }
  }
}

struct AttachmentProcessor {

  // MARK: - Limits
  //
  // Without these, a single dropped file could base64 itself into a request body
  // hundreds of megabytes wide — rejected by the provider after a long upload, or
  // accepted and billed as an enormous prompt.

  /// Images are inlined as base64, which inflates them by roughly a third.
  static let maxImageBytes = 10 * 1_024 * 1_024
  /// Text and PDF source files, before extraction.
  static let maxDocumentBytes = 25 * 1_024 * 1_024
  /// Extracted text per file. ~200k characters is on the order of 50k tokens, which
  /// already exceeds the default context budget; anything beyond it is truncated so
  /// the user sees a note rather than a silently mangled document.
  static let maxExtractedCharacters = 200_000

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

    // Check the size before reading, so an enormous file is refused rather than
    // paged into memory first.
    let limit = type == .image ? maxImageBytes : maxDocumentBytes
    let declaredSize = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
    if let declaredSize, declaredSize > limit {
      throw AttachmentProcessingError.tooLarge(name: url.lastPathComponent, limit: limit)
    }

    let data: Data
    do { data = try Data(contentsOf: url) } catch {
      throw AttachmentProcessingError.unreadable(url.lastPathComponent)
    }
    guard data.count <= limit else {
      throw AttachmentProcessingError.tooLarge(name: url.lastPathComponent, limit: limit)
    }

    let uttype = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
    let mimeType = uttype?.preferredMIMEType ?? "application/octet-stream"
    return AttachedFile(
      url: url, name: url.lastPathComponent,
      type: type, data: data, mimeType: mimeType
    )
  }

  // Returns contextText (for text/PDF files) and imageDataURIs (for images).
  // contextText is stored on the Message but kept out of `content`, so the bubble
  // shows what the user typed while later turns still carry the document.
  // imageDataURIs are "data:<mimeType>;base64,<encoded>" strings.
  static func process(_ attachments: [AttachedFile]) throws -> (
    contextText: String, imageDataURIs: [String]
  ) {
    var blocks: [String] = []
    var imageDataURIs: [String] = []

    for file in attachments {
      switch file.type {
      case .text:
        let text = String(data: file.data, encoding: .utf8) ?? "<binary content>"
        blocks.append(block(name: file.name, text: text))

      case .pdf:
        guard let doc = PDFDocument(data: file.data) else {
          throw AttachmentProcessingError.pdfExtractionFailed(file.name)
        }
        let text = (0..<doc.pageCount)
          .compactMap { doc.page(at: $0)?.string }
          .joined(separator: "\n")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
          throw AttachmentProcessingError.pdfExtractionFailed(file.name)
        }
        blocks.append(block(name: file.name, text: text))

      case .image:
        imageDataURIs.append("data:\(file.mimeType);base64,\(file.data.base64EncodedString())")
      }
    }

    return (blocks.joined(separator: "\n\n"), imageDataURIs)
  }

  private static func block(name: String, text: String) -> String {
    var body = text
    if body.count > maxExtractedCharacters {
      body = String(body.prefix(maxExtractedCharacters))
      body += "\n\n" + String(localized: "attachment.truncated")
    }
    return "[File: \(name)]\n\(body)\n---"
  }
}
