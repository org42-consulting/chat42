import XCTest

@testable import Chat42

/// Guards the hand-maintained `HelpTopic.all` tree.
///
/// The Help window renders this with `ForEach` over ids that *are* the localization
/// keys, so a pasted duplicate does not fail loudly — SwiftUI quietly drops or
/// misplaces a row, and a paragraph of help text disappears from the shipped app.
/// Everything checkable without the `.lproj` bundle is checked here; that the keys
/// resolve to real prose in both languages is `scripts/check-localization.sh`.
final class HelpContentTests: XCTestCase {

  func testEveryTopicHasContent() {
    XCTAssertFalse(HelpTopic.all.isEmpty)
    for topic in HelpTopic.all {
      XCTAssertFalse(topic.blocks.isEmpty, "\(topic.id) is an empty topic")
      XCTAssertFalse(topic.icon.isEmpty, "\(topic.id) has no icon; the list row renders blank")
    }
  }

  func testTopicIdentifiersAreUnique() {
    var seen = Set<String>()
    for topic in HelpTopic.all {
      XCTAssertTrue(seen.insert(topic.id).inserted, "duplicate topic id \(topic.id)")
    }
  }

  /// The list selection is a topic id, and `HelpView` falls back to the first topic
  /// when it cannot resolve one — a stale default would silently pin the window to
  /// the wrong page.
  func testFirstTopicIsResolvable() {
    let first = HelpTopic.all[0]
    XCTAssertEqual(HelpTopic.all.first { $0.id == first.id }?.id, first.id)
  }

  /// Row ids within a topic have to be distinct: `HelpTerm`, `HelpShortcut`, and
  /// `HelpPath` all derive `id` from their own content.
  func testRowIdentifiersAreUniqueWithinEachTopic() {
    for topic in HelpTopic.all {
      var seen = Set<String>()
      for block in topic.blocks {
        for id in rowIds(of: block) {
          XCTAssertTrue(
            seen.insert(id).inserted,
            "\(topic.id) repeats row id '\(id)'; ForEach would drop a row")
        }
      }
    }
  }

  /// Only the shape of a key is checkable here — under `swift test` there is no
  /// `.lproj`, so `String(localized:)` echoes the key back.
  func testEveryKeyIsInTheHelpNamespace() {
    for topic in HelpTopic.all {
      for key in [topic.titleKey] + topic.blocks.flatMap(keys(of:)) {
        XCTAssertTrue(key.hasPrefix("help."), "\(key) is outside the help namespace")
        XCTAssertFalse(key.hasSuffix("."), "\(key) looks truncated")
      }
    }
  }

  /// A key used in two places would make the same sentence appear twice in the
  /// window, which in practice has always meant a copy/paste slip rather than intent.
  func testNoKeyIsUsedTwiceAcrossTheWholeWindow() {
    var seen = Set<String>()
    for topic in HelpTopic.all {
      for key in [topic.titleKey] + topic.blocks.flatMap(keys(of:)) {
        XCTAssertTrue(seen.insert(key).inserted, "\(key) is used more than once")
      }
    }
  }

  /// The shortcut column is verbatim, so it is the one place a real key equivalent
  /// is hard-coded rather than translated.
  func testShortcutsCarryAKeyEquivalent() {
    let shortcuts = HelpTopic.all.flatMap { topic in
      topic.blocks.compactMap { block -> [HelpShortcut]? in
        if case .shortcuts(let rows) = block { return rows }
        return nil
      }
    }.flatMap { $0 }

    XCTAssertFalse(shortcuts.isEmpty, "the shortcut table went missing")
    for shortcut in shortcuts {
      XCTAssertFalse(shortcut.keys.isEmpty)
      XCTAssertFalse(
        shortcut.keys.hasPrefix("help."),
        "\(shortcut.keys) is a localization key in the verbatim column")
    }
  }

  func testPathsArePathsAndNotKeys() {
    let paths = HelpTopic.all.flatMap { topic in
      topic.blocks.compactMap { block -> [HelpPath]? in
        if case .paths(let rows) = block { return rows }
        return nil
      }
    }.flatMap { $0 }

    for path in paths {
      XCTAssertTrue(
        path.path.hasPrefix("~/") || path.path.hasPrefix("/"),
        "\(path.path) does not read as a filesystem path")
    }
  }

  // MARK: - Helpers

  /// Every localization key a block renders.
  private func keys(of block: HelpBlock) -> [String] {
    switch block {
    case .lead(let key), .note(let key):
      return [key]
    case .section(let titleKey, let bodyKey):
      return [titleKey] + (bodyKey.map { [$0] } ?? [])
    case .terms(let terms):
      return terms.flatMap { [$0.termKey, $0.detailKey] }
    case .shortcuts(let rows):
      return rows.map(\.detailKey)
    case .paths(let rows):
      return rows.map(\.detailKey)
    }
  }

  /// The `Identifiable` ids a block hands to `ForEach`.
  private func rowIds(of block: HelpBlock) -> [String] {
    switch block {
    case .lead, .note, .section:
      return []
    case .terms(let terms):
      return terms.map(\.id)
    case .shortcuts(let rows):
      return rows.map(\.id)
    case .paths(let rows):
      return rows.map(\.id)
    }
  }
}
