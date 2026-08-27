import Foundation

/// On-disk store for images produced by a model, kept beside conversations.json.
///
/// This is a deliberate exception to the rule that attachment bytes are never
/// persisted: user-attached files still live only in memory, but generated images
/// have no other source — without this they would vanish on relaunch and leave
/// empty placeholders in the transcript.
enum ImageStore {
  private static var directory: URL {
    FileManager.default
      .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Chat42/GeneratedImages", isDirectory: true)
  }

  /// Writes PNG bytes and returns the generated filename to store on the message.
  static func save(_ data: Data) throws -> String {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let filename = "\(UUID().uuidString).png"
    try data.write(to: directory.appendingPathComponent(filename))
    return filename
  }

  static func url(for filename: String) -> URL {
    // lastPathComponent so a tampered conversations.json cannot walk out of the
    // store directory with a name like "../../secrets".
    directory.appendingPathComponent(URL(fileURLWithPath: filename).lastPathComponent)
  }

  static func load(_ filename: String) -> Data? {
    try? Data(contentsOf: url(for: filename))
  }

  static func delete(_ filename: String) {
    try? FileManager.default.removeItem(at: url(for: filename))
  }
}
