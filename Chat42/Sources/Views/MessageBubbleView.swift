import AppKit
import SwiftUI

struct MessageBubbleView: View {
  @Environment(AppState.self) private var state
  let message: Message
  let conversation: Conversation
  /// Only the newest assistant turn can be regenerated — re-running an earlier one
  /// would have to discard everything after it, which is what editing is for.
  let canRegenerate: Bool
  /// Set when this bubble is one column of a side-by-side comparison, where the
  /// avatar and full width would only get in the way.
  var isComparisonColumn: Bool = false

  @State private var isCopied = false
  @State private var isEditing = false
  @State private var draft = ""

  var isUser: Bool { message.role == .user }
  var isSystem: Bool { message.role == .system }

  var body: some View {
    if isSystem {
      systemBanner
    } else {
      bubbleRow
    }
  }

  // MARK: - System message

  private var systemBanner: some View {
    HStack {
      Image(systemName: "info.circle")
        .font(.caption)
        .foregroundStyle(.secondary)
      Text(message.content)
        .font(.caption)
        .foregroundStyle(.secondary)
        .italic()
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    .frame(maxWidth: .infinity)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      Text(String(format: String(localized: "message.system.a11y"), message.content)))
  }

  // MARK: - Chat bubble row

  private var bubbleRow: some View {
    Group {
      if isComparisonColumn {
        bubbleContent
      } else {
        HStack(alignment: .bottom, spacing: 8) {
          if isUser {
            Spacer(minLength: 60)
            bubbleContent
            userAvatar
          } else {
            assistantAvatar
            bubbleContent
            Spacer(minLength: 60)
          }
        }
        .padding(.horizontal, 16)
      }
    }
    .contextMenu { messageContextMenu }
  }

  @ViewBuilder
  private var messageContextMenu: some View {
    if !message.content.isEmpty {
      Button(String(localized: "message.copy")) { copyContent() }
    }
    if isUser && !conversation.isSending {
      Button(String(localized: "message.edit")) {
        draft = message.content
        isEditing = true
      }
    }
    if !isUser && canRegenerate && !conversation.isSending {
      Button(String(localized: "message.regenerate")) {
        state.regenerate(in: conversation)
      }
      let alternatives = state.availableModels.filter { $0 != message.modelRef }
      if !alternatives.isEmpty {
        Menu(String(localized: "message.retry_with")) {
          ForEach(alternatives) { ref in
            Button(ref.fullLabel) { state.retry(in: conversation, using: ref) }
          }
        }
      }
    }
    Divider()
    Button(String(localized: "message.delete"), role: .destructive) {
      state.deleteMessage(message, in: conversation)
    }
    .disabled(conversation.isSending)
  }

  private var userAvatar: some View {
    Circle()
      .fill(Color.accentColor)
      .frame(width: 28, height: 28)
      .overlay(
        Text(verbatim: "U")
          .font(.caption)
          .fontWeight(.semibold)
          .foregroundStyle(.white)
      )
      .accessibilityHidden(true)
  }

  private var assistantAvatar: some View {
    Circle()
      .fill(Color.primary.opacity(0.1))
      .frame(width: 28, height: 28)
      .overlay(
        Image(systemName: "sparkles")
          .font(.caption2)
          .foregroundStyle(Color.accentColor)
      )
      .accessibilityHidden(true)
  }

  /// Images the app generated and owns bytes for — rendered inline.
  private var generatedImages: [MessageAttachment] {
    message.attachments.filter { $0.type == .image && $0.storedFilename != nil }
  }

  /// User-attached files, whose bytes are never persisted — shown as chips only.
  private var chipAttachments: [MessageAttachment] {
    message.attachments.filter { $0.storedFilename == nil }
  }

  private var bubbleContent: some View {
    VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
      ForEach(generatedImages) { attachment in
        GeneratedImageView(attachment: attachment)
      }

      if !chipAttachments.isEmpty {
        attachmentChips
      }

      if isEditing {
        editor
      } else if !message.content.isEmpty || message.isStreaming {
        // A generated-image message carries no text, so it gets no empty bubble.
        ZStack(alignment: isUser ? .bottomTrailing : .bottomLeading) {
          bubbleText
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
              isUser ? Color.userBubble : Color.assistantBubble,
              in: bubbleShape
            )
            .overlay(
              bubbleShape
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            )

          if message.isStreaming {
            typingIndicator
              .offset(x: isUser ? -10 : 10, y: -6)
          }
        }
      }

      footer
    }
  }

  // MARK: - Inline editor

  private var editor: some View {
    VStack(alignment: .trailing, spacing: 6) {
      TextEditor(text: $draft)
        .font(.body)
        .frame(minWidth: 260, minHeight: 60)
        .scrollContentBackground(.hidden)
        .padding(8)
        .background(Color.assistantBubble, in: bubbleShape)
        .overlay(bubbleShape.strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 1))

      HStack(spacing: 8) {
        Button(String(localized: "message.edit.cancel")) { isEditing = false }
          .buttonStyle(.bordered)
          .controlSize(.small)
        Button(String(localized: "message.edit.resend")) {
          isEditing = false
          state.editAndResend(message, newText: draft, in: conversation)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
  }

  // MARK: - Footer

  private var footer: some View {
    HStack(spacing: 8) {
      Text(message.timestamp.formatted(date: .omitted, time: .shortened))
        .font(.caption2)
        .foregroundStyle(.tertiary)

      if !isUser, let ref = message.modelRef {
        Text(ref.shortLabel)
          .font(.caption2)
          .foregroundStyle(.tertiary)
          .lineLimit(1)
          .help(ref.fullLabel)
      }

      if !isUser && !message.content.isEmpty {
        Button {
          copyContent()
        } label: {
          Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
            .font(.caption2)
            .foregroundStyle(isCopied ? Color.green : Color.secondary.opacity(0.6))
        }
        .buttonStyle(.plain)
        .help(String(localized: "message.copy.help"))
        .accessibilityLabel(Text("message.copy.help"))

        if canRegenerate && !conversation.isSending {
          Button {
            state.regenerate(in: conversation)
          } label: {
            Image(systemName: "arrow.clockwise")
              .font(.caption2)
              .foregroundStyle(Color.secondary.opacity(0.6))
          }
          .buttonStyle(.plain)
          .help(String(localized: "message.regenerate"))
          .accessibilityLabel(Text("message.regenerate"))
        }
      }
    }
  }

  private var attachmentChips: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 6) {
        ForEach(chipAttachments) { attachment in
          AttachmentChipView(name: attachment.name, type: attachment.type)
        }
      }
      .padding(.vertical, 2)
    }
    .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    .accessibilityLabel(Text("message.attachments.a11y"))
  }

  private var bubbleText: some View {
    Group {
      if message.content.isEmpty && message.isStreaming {
        HStack(spacing: 4) {
          ForEach(0..<3, id: \.self) { i in
            Circle()
              .fill(Color.secondary)
              .frame(width: 6, height: 6)
              .opacity(0.6)
              .animation(
                .easeInOut(duration: 0.6)
                  .repeatForever()
                  .delay(Double(i) * 0.2),
                value: message.isStreaming
              )
          }
        }
        .accessibilityLabel(Text("message.waiting.a11y"))
      } else if isUser {
        // Your own input is shown verbatim — no code-block affordances on it.
        Text(message.content)
          .textSelection(.enabled)
          .font(.body)
          .foregroundStyle(.white)
          .fixedSize(horizontal: false, vertical: true)
      } else {
        // Replies are split into prose and fenced code blocks. With no fences this
        // is a single text segment.
        VStack(alignment: .leading, spacing: 8) {
          ForEach(message.segments) { segment in
            switch segment.kind {
            case .text(let body):
              Text(body)
                .textSelection(.enabled)
                .font(.body)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            case .code(let language, let body):
              CodeBlockView(language: language, code: body)
            }
          }
        }
      }
    }
  }

  private var bubbleShape: some InsettableShape {
    RoundedRectangle(cornerRadius: 16)
  }

  private var typingIndicator: some View {
    HStack(spacing: 3) {
      ForEach(0..<3, id: \.self) { _ in
        Circle()
          .fill(Color.accentColor.opacity(0.7))
          .frame(width: 4, height: 4)
      }
    }
    .padding(.horizontal, 6)
    .padding(.vertical, 4)
    .background(Color.primary.opacity(0.08), in: Capsule())
    .accessibilityHidden(true)
  }

  private func copyContent() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(message.content, forType: .string)
    isCopied = true
    Task {
      try? await Task.sleep(for: .milliseconds(1500))
      isCopied = false
    }
  }
}

// MARK: - Colors

extension Color {
  static let userBubble = Color.accentColor
  static let assistantBubble = Color(NSColor.controlBackgroundColor)
}
