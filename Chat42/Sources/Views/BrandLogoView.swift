import AppKit
import SwiftUI

/// The app's own icon, shown on the two empty states.
///
/// Reads `NSImage.applicationIconName` rather than shipping a second copy of the
/// artwork. Whatever the build actually produced — the Liquid Glass icon when
/// `actool` compiled `AppIcon.icon`, the flat fallback when it wasn't available — is
/// what appears here, so this panel can never drift from the icon in the Dock. It
/// also picks up the appearance the system is rendering, which a static PNG could
/// not.
///
/// This replaced a loose `org42-logo-text.png` loaded by bundle lookup, which existed
/// only to work around `build.sh` having no asset catalog to resolve names through.
struct BrandLogoView: View {
  /// Rendered edge length. The icon is square.
  var size: CGFloat = 128

  var body: some View {
    // Looked up per render rather than cached in a `static let`. The old wordmark was
    // cached because it decoded a PNG off disk on every redraw, and the empty states
    // redraw on every keystroke in the sidebar search field. This is a named-image
    // lookup AppKit already caches, so the cost is gone — and holding the result
    // ourselves would pin one appearance instead of following the system's.
    if let icon = NSImage(named: NSImage.applicationIconName) {
      Image(nsImage: icon)
        .resizable()
        .interpolation(.high)
        .scaledToFit()
        .frame(width: size, height: size)
    }
  }
}
