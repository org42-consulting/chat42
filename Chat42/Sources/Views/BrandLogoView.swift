import AppKit
import SwiftUI

/// The Org42 wordmark shown on the two empty states.
///
/// The PNG ships as a loose file in `Contents/Resources/` rather than in a compiled
/// asset catalog, because build.sh deliberately avoids `actool` so that building the
/// app needs only the Command Line Tools and not a full Xcode.
///
/// SwiftUI's `Image("org42-logo-text")` resolves a *name* through the asset catalog,
/// and with no catalog to consult it silently yielded an empty image: the layout
/// still reserved a square 260x260 (a missing image has no aspect ratio to fit) and
/// drew nothing at all, so the wordmark was absent from both empty states with no
/// error anywhere. AppKit's bundle lookup does find the loose file, so resolve it
/// that way and hand SwiftUI a real `NSImage`.
struct BrandLogoView: View {
  /// Rendered width. Height follows the image's own aspect ratio (roughly 3.6:1).
  var width: CGFloat = 260

  var body: some View {
    if let logo = Self.image {
      Image(nsImage: logo)
        .resizable()
        .scaledToFit()
        .frame(width: width)
    }
  }

  /// Resolved once rather than per redraw: this decodes a ~40 KB file, and the empty
  /// states re-render on every keystroke in the sidebar's search field.
  private static let image: NSImage? =
    Bundle.main
    .url(forResource: "org42-logo-text", withExtension: "png")
    .flatMap(NSImage.init(contentsOf:))
}
