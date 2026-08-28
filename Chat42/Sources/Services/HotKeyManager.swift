import AppKit
import Carbon.HIToolbox

/// Registers a system-wide hotkey that summons the app.
///
/// Uses Carbon's `RegisterEventHotKey` rather than `NSEvent.addGlobalMonitorForEvents`
/// on purpose: the NSEvent route needs Accessibility permission — a scary system
/// prompt for a chat app — while `RegisterEventHotKey` needs none and has been the
/// supported way to claim a global shortcut since long before that API existed.
///
/// Not `@MainActor`: the Carbon event callback is a bare C function pointer that
/// cannot capture context or hop actors, so it reaches the singleton directly and
/// bounces the work to the main queue itself.
final class HotKeyManager: @unchecked Sendable {
  static let shared = HotKeyManager()

  /// Four-character signature 'CH42', identifying this app's hotkey registration.
  private static let signature: OSType = 0x4348_3432
  private static let hotKeyID: UInt32 = 1

  private let lock = NSLock()
  private var storedHandler: (@Sendable () -> Void)?
  private var hotKeyRef: EventHotKeyRef?
  private var eventHandlerRef: EventHandlerRef?

  private init() {}

  /// Default is ⌃⌥Space — Command-Space and Option-Space are already spoken for by
  /// Spotlight and by several popular launchers.
  static let defaultKeyCode = UInt32(kVK_Space)
  static let defaultModifiers = UInt32(controlKey | optionKey)

  func setHandler(_ handler: @escaping @Sendable () -> Void) {
    lock.lock()
    storedHandler = handler
    lock.unlock()
  }

  fileprivate func fire() {
    lock.lock()
    let handler = storedHandler
    lock.unlock()
    guard let handler else { return }
    DispatchQueue.main.async { handler() }
  }

  @discardableResult
  func register(
    keyCode: UInt32 = HotKeyManager.defaultKeyCode,
    modifiers: UInt32 = HotKeyManager.defaultModifiers
  ) -> Bool {
    unregister()

    var eventType = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard),
      eventKind: UInt32(kEventHotKeyPressed)
    )

    let installStatus = InstallEventHandler(
      GetApplicationEventTarget(),
      { _, event, _ -> OSStatus in
        guard let event else { return OSStatus(eventNotHandledErr) }
        var id = EventHotKeyID()
        let status = GetEventParameter(
          event,
          EventParamName(kEventParamDirectObject),
          EventParamType(typeEventHotKeyID),
          nil,
          MemoryLayout<EventHotKeyID>.size,
          nil,
          &id
        )
        guard status == noErr,
          id.signature == HotKeyManager.signature,
          id.id == HotKeyManager.hotKeyID
        else { return OSStatus(eventNotHandledErr) }
        HotKeyManager.shared.fire()
        return noErr
      },
      1,
      &eventType,
      nil,
      &eventHandlerRef
    )
    guard installStatus == noErr else { return false }

    let id = EventHotKeyID(signature: Self.signature, id: Self.hotKeyID)
    // Fails when another app already owns the combination — reported rather than
    // trapped, so the caller can tell the user instead of silently doing nothing.
    let status = RegisterEventHotKey(
      keyCode, modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
    return status == noErr
  }

  func unregister() {
    if let hotKeyRef {
      UnregisterEventHotKey(hotKeyRef)
      self.hotKeyRef = nil
    }
    if let eventHandlerRef {
      RemoveEventHandler(eventHandlerRef)
      self.eventHandlerRef = nil
    }
  }
}
