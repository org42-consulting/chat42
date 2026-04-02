import SwiftUI
import AppKit

struct ChatInputView: View {
    @Environment(AppState.self) private var state
    @Environment(MLXService.self) private var mlxService
    @Binding var inputText: String
    var onSend: () -> Void

    @State private var isFocused: Bool = false
    @State private var textEditorHeight: CGFloat = 36

    var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !state.isSending
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider()

            HStack(alignment: .bottom, spacing: 10) {
                inputField
                sendButton
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            HStack {
                Text("input.hint")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                if let label = selectedModelLabel {
                    Text(label)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 6)
        }
        .background(.ultraThinMaterial)
        .onAppear { isFocused = true }
    }

    // MARK: - Input field

    private var inputField: some View {
        ZStack(alignment: .topLeading) {
            GrowingTextView(
                text: $inputText,
                height: $textEditorHeight,
                isFocused: $isFocused,
                maxHeight: 160,
                onCommit: { if canSend { onSend() } }
            )
            .frame(height: textEditorHeight)

            if inputText.isEmpty {
                Text("input.placeholder")
                    .font(.body)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 11)
                    .padding(.top, 8)
                    .allowsHitTesting(false)
            }
        }
        .background(Color.inputBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    isFocused ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.12),
                    lineWidth: 1
                )
        )
    }

    // MARK: - Send button

    private var sendButton: some View {
        Button {
            if state.isSending { state.stopStreaming() } else { onSend() }
        } label: {
            ZStack {
                Circle()
                    .fill(state.isSending ? Color.red.opacity(0.85) : (canSend ? Color.accentColor : Color.primary.opacity(0.12)))
                    .frame(width: 36, height: 36)
                Image(systemName: state.isSending ? "stop.fill" : "arrow.up")
                    .font(.callout)
                    .fontWeight(.semibold)
                    .foregroundStyle(state.isSending || canSend ? .white : Color.secondary)
            }
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.return, modifiers: [])
        .disabled(!canSend && !state.isSending)
        .help(state.isSending
              ? String(localized: "input.stop.help")
              : String(localized: "input.send.help"))
        .animation(.easeInOut(duration: 0.15), value: state.isSending)
        .animation(.easeInOut(duration: 0.15), value: canSend)
    }

    private var selectedModelLabel: String? {
        switch state.activeBackend {
        case .ollama:   return state.selectedOllamaModel.map { "Ollama · \($0.displayName)" }
        case .mlx:      return mlxService.loadedModelId.map { "MLX · \($0.components(separatedBy: "/").last ?? $0)" }
        case .gateway:  return state.selectedGatewayModel.map { "Gateway · \($0.displayName)" }
        }
    }
}

// MARK: - Growing NSTextView

private struct GrowingTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    @Binding var isFocused: Bool
    let maxHeight: CGFloat
    let onCommit: () -> Void

    private static let inset = NSSize(width: 6, height: 8)

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        let tv = FocusAwareTextView()
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.allowsUndo = true
        tv.font = .preferredFont(forTextStyle: .body, options: [:])
        tv.drawsBackground = false
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.textContainerInset = Self.inset
        tv.onFocusChange = { focused in
            DispatchQueue.main.async { context.coordinator.parent.isFocused = focused }
        }

        scrollView.documentView = tv
        DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let tv = scrollView.documentView as? NSTextView else { return }
        if tv.string != text {
            let sel = tv.selectedRanges
            tv.string = text
            tv.selectedRanges = sel
        }
        recalcHeight(tv)
    }

    func recalcHeight(_ tv: NSTextView) {
        guard let lm = tv.layoutManager, let tc = tv.textContainer else { return }
        lm.ensureLayout(for: tc)
        let used = lm.usedRect(for: tc).height
        let newH = min(max(36, used + Self.inset.height * 2), maxHeight)
        if abs(newH - height) > 0.5 {
            DispatchQueue.main.async { self.height = newH }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: GrowingTextView
        init(_ parent: GrowingTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
            parent.recalcHeight(tv)
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) {
                if NSEvent.modifierFlags.contains(.shift) {
                    textView.insertNewlineIgnoringFieldEditor(nil)
                    return true
                }
                parent.onCommit()
                return true
            }
            return false
        }
    }
}

private final class FocusAwareTextView: NSTextView {
    var onFocusChange: ((Bool) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { onFocusChange?(true) }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { onFocusChange?(false) }
        return result
    }
}

// MARK: - Color

extension Color {
    static let inputBackground = Color(NSColor.textBackgroundColor)
}
