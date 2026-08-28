import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Manages the documents kept in a conversation's context for every turn.
///
/// Distinct from an attachment, which is relevant to the turn it was dropped on and
/// then recedes. Pinning is for the material the conversation is *about*.
struct PinnedDocumentsView: View {
  @Environment(AppState.self) private var state
  let conversation: Conversation

  @State private var errorMessage: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("chat.pinned.title")
        .font(.headline)

      Text("chat.pinned.description")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      if conversation.pinnedDocuments.isEmpty {
        Text("chat.pinned.empty")
          .font(.callout)
          .foregroundStyle(.tertiary)
          .frame(maxWidth: .infinity, alignment: .center)
          .padding(.vertical, 12)
      } else {
        VStack(spacing: 4) {
          ForEach(conversation.pinnedDocuments) { document in
            HStack(spacing: 8) {
              Image(systemName: "doc.text")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
              VStack(alignment: .leading, spacing: 1) {
                Text(document.name)
                  .font(.callout)
                  .lineLimit(1)
                  .truncationMode(.middle)
                Text(
                  "\(document.formattedSize) · \(ContextBuilder.estimatedTokens(document.text)) \(String(localized: "chat.pinned.tokens"))"
                )
                .font(.caption2)
                .foregroundStyle(.tertiary)
              }
              Spacer()
              Button {
                state.unpinDocument(document, from: conversation)
              } label: {
                Image(systemName: "xmark.circle.fill")
                  .foregroundStyle(.secondary)
              }
              .buttonStyle(.plain)
              .help(String(localized: "chat.pinned.remove"))
              .accessibilityLabel(
                Text(String(format: String(localized: "chat.pinned.remove.a11y"), document.name)))
            }
            .padding(.vertical, 3)
          }
        }
      }

      if let errorMessage {
        Text(errorMessage)
          .font(.caption)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      }

      Divider()

      HStack {
        Button {
          addDocuments()
        } label: {
          Label(String(localized: "chat.pinned.add"), systemImage: "plus")
        }
        Spacer()
        // Pinned text is charged against the same budget as history, so a large
        // file quietly leaves less room for the conversation itself.
        let usage = state.contextUsage(for: conversation)
        Text(
          String(
            format: String(localized: "chat.context.usage"),
            usage.used, usage.limit)
        )
        .font(.caption2)
        .foregroundStyle(usage.isTrimming ? .orange : .secondary)
        .monospacedDigit()
      }
    }
    .padding(14)
    .frame(width: 340)
  }

  private func addDocuments() {
    errorMessage = nil
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = true
    // Images are excluded on purpose: pinning stores extracted text, and an image
    // has none to keep in context.
    panel.allowedContentTypes = [.text, .pdf]
    panel.begin { response in
      guard response == .OK else { return }
      DispatchQueue.main.async {
        for url in panel.urls {
          do {
            let file = try AttachmentProcessor.makeAttachedFile(url: url)
            try state.pinDocument(file, to: conversation)
          } catch {
            errorMessage = error.localizedDescription
          }
        }
      }
    }
  }
}
