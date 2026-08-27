import XCTest

@testable import Chat42

final class AttachmentProcessorTests: XCTestCase {

  private func textFile(_ name: String, _ body: String) -> AttachedFile {
    AttachedFile(
      url: URL(fileURLWithPath: "/tmp/\(name)"), name: name, type: .text,
      data: Data(body.utf8), mimeType: "text/plain")
  }

  func testTextFileBecomesALabelledBlock() throws {
    let (context, images) = try AttachmentProcessor.process([textFile("notes.txt", "hello")])
    XCTAssertTrue(context.contains("[File: notes.txt]"))
    XCTAssertTrue(context.contains("hello"))
    XCTAssertTrue(images.isEmpty)
  }

  func testImageBecomesADataURI() throws {
    let png = Data([0x89, 0x50, 0x4E, 0x47])
    let file = AttachedFile(
      url: URL(fileURLWithPath: "/tmp/a.png"), name: "a.png", type: .image,
      data: png, mimeType: "image/png")

    let (context, images) = try AttachmentProcessor.process([file])
    XCTAssertTrue(context.isEmpty)
    XCTAssertEqual(images, ["data:image/png;base64,\(png.base64EncodedString())"])
  }

  func testMultipleFilesAreSeparated() throws {
    let (context, _) = try AttachmentProcessor.process([
      textFile("a.txt", "aaa"), textFile("b.txt", "bbb"),
    ])
    XCTAssertTrue(context.contains("[File: a.txt]"))
    XCTAssertTrue(context.contains("[File: b.txt]"))
  }

  /// A huge document would otherwise be inlined whole, blowing the context budget
  /// and the bill along with it.
  func testOversizedTextIsTruncatedWithANotice() throws {
    let huge = String(repeating: "x", count: AttachmentProcessor.maxExtractedCharacters + 5_000)
    let (context, _) = try AttachmentProcessor.process([textFile("big.txt", huge)])

    XCTAssertLessThan(context.count, huge.count)
    XCTAssertTrue(context.contains(String(localized: "attachment.truncated")))
  }

  func testTextUnderTheLimitIsNotTruncated() throws {
    let body = String(repeating: "y", count: 1_000)
    let (context, _) = try AttachmentProcessor.process([textFile("small.txt", body)])
    XCTAssertFalse(context.contains(String(localized: "attachment.truncated")))
  }

  func testEmptyAttachmentListProducesNothing() throws {
    let (context, images) = try AttachmentProcessor.process([])
    XCTAssertTrue(context.isEmpty)
    XCTAssertTrue(images.isEmpty)
  }

  func testOversizedFileIsRejectedBeforeItIsSent() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let path = directory.appendingPathComponent("huge.txt")
    let oversized = Data(repeating: 0x61, count: AttachmentProcessor.maxDocumentBytes + 1_024)
    try oversized.write(to: path)

    XCTAssertThrowsError(try AttachmentProcessor.makeAttachedFile(url: path)) { error in
      guard case AttachmentProcessingError.tooLarge = error else {
        return XCTFail("expected tooLarge, got \(error)")
      }
    }
  }
}

@MainActor
final class MLXDownloadPathTests: XCTestCase {

  private let root = URL(fileURLWithPath: "/tmp/models/repo")

  /// The bug this covers: flattening to the last path component made
  /// `original/model.safetensors` overwrite `model.safetensors`.
  func testNestedPathsKeepTheirDirectory() throws {
    let resolved = try MLXService.destination(for: "original/model.safetensors", in: root)
    XCTAssertEqual(resolved.path, "/tmp/models/repo/original/model.safetensors")

    let top = try MLXService.destination(for: "model.safetensors", in: root)
    XCTAssertEqual(top.path, "/tmp/models/repo/model.safetensors")
    XCTAssertNotEqual(resolved.path, top.path)
  }

  /// The file list arrives over the network, so a traversal in a name is hostile
  /// input rather than a path.
  func testTraversalIsRefused() {
    for hostile in ["../escape.json", "a/../../escape.json", "/etc/passwd", "./x.json"] {
      XCTAssertThrowsError(try MLXService.destination(for: hostile, in: root)) { error in
        guard case MLXServiceError.unsafeArchivePath = error else {
          return XCTFail("expected unsafeArchivePath for \(hostile), got \(error)")
        }
      }
    }
  }

  func testEmptyPathIsRefused() {
    XCTAssertThrowsError(try MLXService.destination(for: "", in: root))
  }
}
