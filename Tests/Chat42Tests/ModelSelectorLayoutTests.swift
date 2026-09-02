import AppKit
import XCTest

@testable import Chat42

/// Guards the backend segmented picker in `ModelSelectorView` against a stale width.
///
/// The picker used to carry `.frame(width: 160)`, sized when `AIBackend` had two
/// cases (Ollama/MLX, 118pt). Adding `Gateway` pushed the intrinsic width to 194pt,
/// and because SwiftUI's `.frame(width:)` sets the layout size *without clipping*,
/// AppKit kept drawing the control at its full width centred in the 160pt slot —
/// spilling ~17pt past each edge and overlapping the sidebar controls on the left
/// and the model picker on the right. Nothing failed; the toolbar just rendered
/// on top of itself.
///
/// A layout this far inside SwiftUI is not reachable from a unit test, so the
/// invariant is enforced where it actually broke: no hardcoded width narrower than
/// the segments need may be pinned onto the picker.
final class ModelSelectorLayoutTests: XCTestCase {

  /// Intrinsic width AppKit needs for one segment per `AIBackend` case.
  @MainActor
  private func intrinsicSegmentedWidth() -> CGFloat {
    let control = NSSegmentedControl()
    control.segmentCount = AIBackend.allCases.count
    for (index, backend) in AIBackend.allCases.enumerated() {
      control.setLabel(backend.rawValue, forSegment: index)
    }
    control.sizeToFit()
    return control.fittingSize.width
  }

  private func modelSelectorSource() throws -> String {
    // Tests/Chat42Tests/<this file> -> repo root
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let source = root.appending(path: "Chat42/Sources/Views/ModelSelectorView.swift")
    return try String(contentsOf: source, encoding: .utf8)
  }

  /// The bug itself: a fixed width that no longer fits the segments.
  @MainActor
  func testBackendPickerIsNotPinnedNarrowerThanItsSegments() throws {
    let required = intrinsicSegmentedWidth()
    let source = try modelSelectorSource()

    // Any `.frame(width: N)` between `.pickerStyle(.segmented)` and the end of the
    // backend picker's modifier chain applies to the segmented control.
    guard let segmentedRange = source.range(of: ".pickerStyle(.segmented)") else {
      XCTFail("backend picker is no longer a segmented picker; revisit this guard")
      return
    }
    let chain = source[segmentedRange.upperBound...].prefix(400)

    let pattern = try NSRegularExpression(pattern: #"\.frame\(width:\s*([0-9.]+)\)"#)
    let text = String(chain)
    let match = pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))

    guard let match, let range = Range(match.range(at: 1), in: text),
      let pinned = Double(text[range])
    else {
      return  // No hardcoded width: it sizes to content and cannot go stale.
    }

    XCTAssertGreaterThanOrEqual(
      CGFloat(pinned), required,
      """
      The backend picker is pinned to \(pinned)pt but its \(AIBackend.allCases.count) \
      segments need \(required)pt. SwiftUI will not clip the overflow — the control \
      draws over its toolbar neighbours instead. Drop the fixed width, or raise it.
      """
    )
  }

  /// Explains the regression: the constant was correct for two backends.
  @MainActor
  func testAddingABackendOutgrewTheOriginalTwoSegmentWidth() {
    let control = NSSegmentedControl()
    control.segmentCount = 2
    control.setLabel(AIBackend.ollama.rawValue, forSegment: 0)
    control.setLabel(AIBackend.mlx.rawValue, forSegment: 1)
    control.sizeToFit()

    XCTAssertLessThan(
      control.fittingSize.width, intrinsicSegmentedWidth(),
      "each added backend widens the control; the layout has to follow the case count")
  }
}
