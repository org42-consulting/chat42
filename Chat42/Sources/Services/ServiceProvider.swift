import AppKit

/// Backs the "Ask Chat42" entry in the system Services menu.
///
/// Lets any app hand a text selection straight to a new conversation — select in a
/// browser, a PDF, an editor, then Services → Ask Chat42 — which removes the
/// copy/switch/paste round trip that otherwise stands between reading something and
/// asking about it.
///
/// The corresponding `NSServices` declaration lives in Info.plist; without both
/// halves the menu item never appears.
final class ServiceProvider: NSObject {
  /// Set by the app at launch. Takes the selected text.
  @MainActor var onText: ((String) -> Void)?

  @objc func askChat42(
    _ pasteboard: NSPasteboard,
    userData: String?,
    error: AutoreleasingUnsafeMutablePointer<NSString?>
  ) {
    guard let text = pasteboard.string(forType: .string),
      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      error.pointee = String(localized: "service.no_text") as NSString
      return
    }

    // The Services machinery calls this on the main thread, but it is not typed as
    // such, so the hop is explicit rather than assumed.
    Task { @MainActor in
      NSApp.activate(ignoringOtherApps: true)
      onText?(text)
    }
  }
}
