import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Renders a model-generated image from `ImageStore`, with save and copy actions.
struct GeneratedImageView: View {
  let attachment: MessageAttachment
  @State private var isCopied = false

  private var image: NSImage? {
    guard let filename = attachment.storedFilename,
      let data = ImageStore.load(filename)
    else { return nil }
    return NSImage(data: data)
  }

  var body: some View {
    if let image {
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

          Button { copy(image) } label: {
            Label(
              isCopied ? String(localized: "image.copied") : String(localized: "image.copy"),
              systemImage: isCopied ? "checkmark" : "doc.on.doc")
          }
          .help(String(localized: "image.copy"))
        }
        .buttonStyle(.plain)
        .font(.caption)
        .foregroundStyle(isCopied ? Color.green : Color.secondary)
      }
    } else {
      // The file is gone — the conversation was cleared, or the store was pruned.
      Label(String(localized: "image.missing"), systemImage: "photo.badge.exclamationmark")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
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
      try? await Task.sleep(nanoseconds: 1_500_000_000)
      isCopied = false
    }
  }
}
