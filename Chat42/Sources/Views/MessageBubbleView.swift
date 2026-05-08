import AppKit
import SwiftUI

struct MessageBubbleView: View {
  let message: Message
  @State private var isCopied = false

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
  }

  // MARK: - Chat bubble row

  private var bubbleRow: some View {
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

  private var userAvatar: some View {
    Circle()
      .fill(Color.accentColor)
      .frame(width: 28, height: 28)
      .overlay(
        Text("U")
          .font(.caption)
          .fontWeight(.semibold)
          .foregroundStyle(.white)
      )
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
  }

  private var bubbleContent: some View {
    VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
      if !message.attachments.isEmpty {
        attachmentChips
      }
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

      HStack(spacing: 8) {
        Text(message.timestamp.formatted(date: .omitted, time: .shortened))
          .font(.caption2)
          .foregroundStyle(.tertiary)

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
        }
      }
    }
  }

  private var attachmentChips: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 6) {
        ForEach(message.attachments) { attachment in
          AttachmentChipView(name: attachment.name, type: attachment.type)
        }
      }
      .padding(.vertical, 2)
    }
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
      } else {
        SelectableText(message.content)
          .textSelection(.enabled)
          .font(.body)
          .foregroundStyle(isUser ? .white : .primary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private var bubbleShape: some InsettableShape {
    RoundedRectangle(cornerRadius: 16)
  }

  private var typingIndicator: some View {
    HStack(spacing: 3) {
      ForEach(0..<3, id: \.self) { i in
        Circle()
          .fill(Color.accentColor.opacity(0.7))
          .frame(width: 4, height: 4)
      }
    }
    .padding(.horizontal, 6)
    .padding(.vertical, 4)
    .background(Color.primary.opacity(0.08), in: Capsule())
  }

  private func copyContent() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(message.content, forType: .string)
    isCopied = true
    Task {
      try? await Task.sleep(nanoseconds: 1_500_000_000)
      isCopied = false
    }
  }
}

// MARK: - SelectableText (renders markdown-lite)

struct SelectableText: View {
  let text: String
  init(_ text: String) { self.text = text }

  var body: some View {
    Text(attributedContent)
  }

  private var attributedContent: AttributedString {
    (try? AttributedString(markdown: text)) ?? AttributedString(text)
  }
}

// MARK: - Colors

extension Color {
  static let userBubble = Color.accentColor
  static let assistantBubble = Color(NSColor.controlBackgroundColor)
}
