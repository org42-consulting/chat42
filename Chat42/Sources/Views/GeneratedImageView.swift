import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Renders a model-generated image from `ImageStore`, with save and copy actions.
struct GeneratedImageView: View {
  let attachment: MessageAttachment
  @State private var isCopied = false
  /// Loaded once per appearance. As a computed property this re-read and re-decoded
  /// the PNG on every body evaluation — including on every token of a later reply
  /// streaming into the same conversation.
  @State private var image: NSImage?
  @State private var didAttemptLoad = false

  var body: some View {
    Group {
      if let image {
        loaded(image)
      } else if didAttemptLoad {
        // The file is gone — the conversation was cleared, or the store was pruned.
        Label(String(localized: "image.missing"), systemImage: "photo.badge.exclamationmark")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        ProgressView()
          .controlSize(.small)
          .frame(width: 120, height: 120)
      }
    }
    .task(id: attachment.storedFilename) {
      await load()
    }
  }

  private func loaded(_ image: NSImage) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Image(nsImage: image)
        .resizable()
        .scaledToFit()
        .frame(maxWidth: 360, maxHeight: 360)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
          RoundedRectangle(cornerRadius: 12)
            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .accessibilityLabel(Text(attachment.name))

      HStack(spacing: 12) {
        Button(action: save) {
          Label(String(localized: "image.save"), systemImage: "square.and.arrow.down")
        }
        .help(String(localized: "image.save"))
        .accessibilityLabel(Text("image.save"))

        Button {
          copy(image)
        } label: {
          Label(
            isCopied ? String(localized: "image.copied") : String(localized: "image.copy"),
            systemImage: isCopied ? "checkmark" : "doc.on.doc")
        }
        .help(String(localized: "image.copy"))
        .accessibilityLabel(Text("image.copy"))
      }
      .buttonStyle(.plain)
      .font(.caption)
      .foregroundStyle(isCopied ? Color.green : Color.secondary)
    }
  }

  /// Reads and decodes off the main actor: a 1024×1024 PNG decode is long enough to
  /// drop frames if it happens during a scroll.
  private func load() async {
    guard let filename = attachment.storedFilename else {
      didAttemptLoad = true
      return
    }
    let decoded = await Task.detached(priority: .userInitiated) {
      ImageStore.load(filename).flatMap { NSImage(data: $0) }
    }.value
    image = decoded
    didAttemptLoad = true
  }

  private func save() {
    guard let filename = attachment.storedFilename else { return }
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.png]
    panel.nameFieldStringValue = attachment.name
    panel.begin { response in
      guard response == .OK, let destination = panel.url else { return }
      DispatchQueue.main.async {
        guard let data = ImageStore.load(filename) else { return }
        try? data.write(to: destination)
      }
    }
  }

  private func copy(_ image: NSImage) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.writeObjects([image])
    isCopied = true
    Task {
      try? await Task.sleep(for: .milliseconds(1500))
      isCopied = false
    }
  }
}
