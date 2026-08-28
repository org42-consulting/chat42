import AppKit
import SwiftUI

/// The menu bar popover: ask something without leaving whatever you were doing.
///
/// Backed by a real conversation in `AppState` rather than a parallel mini-chat, so
/// anything asked here is in the sidebar afterwards and "Open in Chat42" is a
/// change of view rather than a hand-off.
struct QuickAskView: View {
  @Environment(AppState.self) private var state

  @State private var input = ""
  @State private var conversation: Conversation?
  @FocusState private var isInputFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 6) {
        Image(systemName: "bubble.left.and.bubble.right.fill")
          .foregroundStyle(Color.accentColor)
          .accessibilityHidden(true)
        Text("quick.title")
          .font(.headline)
        Spacer()
        Text(state.selectedModelName)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }

      TextField(String(localized: "quick.placeholder"), text: $input, axis: .vertical)
        .textFieldStyle(.roundedBorder)
        .lineLimit(1...4)
        .focused($isInputFocused)
        .onSubmit(send)
        .accessibilityLabel(Text("quick.placeholder"))

      if let conversation, let reply = conversation.messages.last, reply.role == .assistant {
        Divider()
        ScrollView {
          Text(reply.content.isEmpty ? String(localized: "quick.thinking") : reply.content)
            .font(.callout)
            .foregroundStyle(reply.isError ? Color.red : .primary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 220)
      }

      HStack {
        if let conversation, conversation.isSending {
          Button(String(localized: "input.stop.help")) {
            state.stopStreaming(in: conversation)
          }
          .controlSize(.small)
        }
        Spacer()
        if conversation != nil {
          Button(String(localized: "quick.open")) { openInApp() }
            .controlSize(.small)
        }
        Button(String(localized: "quick.send"), action: send)
          .buttonStyle(.borderedProminent)
          .controlSize(.small)
          .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .padding(14)
    .frame(width: 380)
    .onAppear { isInputFocused = true }
  }

  private func send() {
    let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    input = ""
    // A fresh conversation per question: the popover is for one-offs, and threading
    // them together would make the sidebar a dumping ground.
    let conv = state.newConversation()
    conversation = conv
    state.sendMessage(text)
  }

  private func openInApp() {
    if let conversation { state.selectedConversationId = conversation.id }
    NSApp.activate(ignoringOtherApps: true)
    // The main scene is the only ordinary window; Settings and the popover are not.
    NSApp.windows.first { $0.isVisible && $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
  }
}
