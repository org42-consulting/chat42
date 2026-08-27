import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A fenced code block, with copy and save-to-file actions.
struct CodeBlockView: View {
  let language: String?
  let code: String
  @State private var isCopied = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 10) {
        Text(language?.uppercased() ?? String(localized: "code.plain"))
          .font(.caption2)
          .fontWeight(.medium)
          .foregroundStyle(.secondary)

        Spacer()

        Button { copy() } label: {
          Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
            .foregroundStyle(isCopied ? Color.green : Color.secondary)
        }
        .help(String(localized: "code.copy"))

        Button(action: save) {
          Image(systemName: "square.and.arrow.down")
            .foregroundStyle(.secondary)
        }
        .help(String(localized: "code.save"))
      }
      .buttonStyle(.plain)
      .font(.caption)
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .background(Color.primary.opacity(0.05))

      ScrollView(.horizontal, showsIndicators: false) {
        Text(code)
          .font(.system(.callout, design: .monospaced))
          .textSelection(.enabled)
          .padding(10)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
    )
  }

  // MARK: - Actions

  private func copy() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(code, forType: .string)
    isCopied = true
    Task {
      try? await Task.sleep(nanoseconds: 1_500_000_000)
      isCopied = false
    }
  }

  private func save() {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = "snippet.\(fileExtension)"
    if let type = UTType(filenameExtension: fileExtension) {
      panel.allowedContentTypes = [type]
    }
    panel.begin { response in
      guard response == .OK, let url = panel.url else { return }
      DispatchQueue.main.async {
        try? Data(code.utf8).write(to: url)
      }
    }
  }

  /// Maps the fence's language tag to a file extension, defaulting to .txt.
  private var fileExtension: String {
    guard let language = language?.lowercased() else { return "txt" }
    return Self.extensions[language] ?? "txt"
  }

  private static let extensions: [String: String] = [
    "bash": "sh", "c": "c", "cpp": "cpp", "c++": "cpp", "css": "css", "go": "go",
    "html": "html", "java": "java", "javascript": "js", "js": "js", "json": "json",
    "kotlin": "kt", "markdown": "md", "md": "md", "objective-c": "m", "php": "php",
    "python": "py", "py": "py", "ruby": "rb", "rb": "rb", "rust": "rs", "rs": "rs",
    "shell": "sh", "sh": "sh", "sql": "sql", "swift": "swift", "toml": "toml",
    "ts": "ts", "typescript": "ts", "xml": "xml", "yaml": "yml", "yml": "yml",
  ]
}
