import XCTest

@testable import Chat42

/// Guards the hand-maintained `MLXModelInfo.bundled` catalog. Every entry is a
/// multi-gigabyte download the user commits to from one click, so the cheap
/// invariants are worth asserting rather than eyeballing.
final class MLXModelCatalogTests: XCTestCase {

  func testCatalogIsNotEmpty() {
    XCTAssertFalse(MLXModelInfo.bundled.isEmpty)
  }

  func testEveryEntryHasAPlausibleSize() {
    for model in MLXModelInfo.bundled {
      XCTAssertGreaterThan(
        model.approximateSizeGB, 0,
        "\(model.name) has no download estimate; the row would render '~Zero KB'")
      // Nothing in a curated on-device list should plausibly exceed this, so a
      // fat-fingered extra digit trips here instead of in the UI.
      XCTAssertLessThan(model.approximateSizeGB, 100, "\(model.name) size looks like a typo")
    }
  }

  /// The Settings list renders `bundled` in array order and the descriptions lean on
  /// that ("strong for its size"), so the ladder has to actually ascend.
  func testCatalogIsOrderedSmallestFirst() {
    let sizes = MLXModelInfo.bundled.map(\.approximateSizeGB)
    XCTAssertEqual(
      sizes, sizes.sorted(),
      "bundled is out of order; Settings shows it as a size ladder")
  }

  func testIdentifiersAreUniqueAndMatchTheirRepo() {
    var seen = Set<String>()
    for model in MLXModelInfo.bundled {
      XCTAssertTrue(seen.insert(model.id).inserted, "duplicate id \(model.id)")
      // `id` doubling as `repoId` is what lets ForEach rows and download state
      // line up; a mismatch would show one model's progress on another's row.
      XCTAssertEqual(model.id, model.repoId, "\(model.name) id/repoId disagree")
      XCTAssertTrue(
        model.repoId.hasPrefix("mlx-community/"),
        "\(model.repoId) is not an mlx-community repo")
    }
  }

  /// Only the shape of the key is checkable here: the `.lproj` resources are bundled
  /// by project.yml, not by Package.swift, so under `swift test` `String(localized:)`
  /// echoes the key back. scripts/check-localization.sh asserts the keys resolve.
  func testDescriptionKeysAreWellFormed() {
    for model in MLXModelInfo.bundled {
      XCTAssertTrue(
        model.descriptionKey.hasPrefix("mlx.model.")
          && model.descriptionKey.hasSuffix(".desc"),
        "\(model.descriptionKey) breaks the mlx.model.<slug>.desc convention")
    }
  }

  func testFormattedSizeIsHumanReadable() {
    for model in MLXModelInfo.bundled {
      let formatted = model.formattedApproximateSize
      XCTAssertTrue(
        formatted.contains("MB") || formatted.contains("GB"),
        "\(model.name) formatted as '\(formatted)'")
      XCTAssertFalse(formatted.contains("Zero"), "\(model.name) formatted as '\(formatted)'")
    }
  }

  /// Sub-gigabyte entries should read as MB, not "0.4 GB" — the ladder starts small
  /// and that rung is the whole reason a size is shown before downloading.
  func testSubGigabyteModelsRenderAsMegabytes() {
    for model in MLXModelInfo.bundled where model.approximateSizeGB < 1 {
      XCTAssertTrue(
        model.formattedApproximateSize.contains("MB"),
        "\(model.name) rendered as '\(model.formattedApproximateSize)'")
    }
  }
}
