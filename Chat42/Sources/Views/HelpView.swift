import AppKit
import SwiftUI

/// Opens and reuses the Help window.
///
/// AppKit rather than a SwiftUI `Window` scene, which is what this started as. A
/// `Window` declared in the `App` body is created at launch whether or not anyone
/// asked for it: closing it and quitting, with no saved application state on disk,
/// still brought it back on the next launch. Help that shows up uninvited every time
/// you open the app is worse than no Help window. `defaultLaunchBehavior(.suppressed)`
/// fixes that, and is macOS 15; this app targets 14.
///
/// Held as a singleton with the window retained, so reopening from the menu brings
/// back the one that exists — including the topic you were reading — rather than
/// stacking up copies.
@MainActor
final class HelpWindowPresenter {
  static let shared = HelpWindowPresenter()

  /// Autosave name for the window frame. Matches the id the scene-based version
  /// used, so a frame the user already dragged into place survives the change.
  static let frameAutosaveName = "chat42.help"

  private var window: NSWindow?

  private init() {}

  func show() {
    if let window {
      window.makeKeyAndOrderFront(nil)
      return
    }

    let controller = NSHostingController(rootView: HelpView())
    let window = NSWindow(contentViewController: controller)
    window.title = String(localized: "help.window.title")
    window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
    window.setContentSize(NSSize(width: 840, height: 600))
    window.contentMinSize = NSSize(width: 720, height: 470)
    // Closing must not deallocate it, since the menu item reopens this instance.
    window.isReleasedWhenClosed = false
    window.center()
    // After `center()`, so a saved frame wins and an unsaved one lands centred.
    window.setFrameAutosaveName(Self.frameAutosaveName)
    self.window = window
    window.makeKeyAndOrderFront(nil)
  }
}

/// The Help window: one topic per aspect of the app, listed down the left.
///
/// The content is declared as data rather than assembled view by view. Fourteen
/// topics of hand-built stacks would be fourteen places to get the type scale and
/// the spacing subtly different, and every string here has to exist in both
/// languages — a flat list of blocks keeps the keys as literals in one place, where
/// `scripts/check-localization.sh` can see them.
struct HelpView: View {
  @State private var selectedTopicId: String = HelpTopic.all[0].id

  // The Appearance setting is app-wide, so a Help window that followed the system
  // instead would be a light panel beside a dark chat.
  @AppStorage("colorScheme") private var colorSchemeRaw: String = "system"

  private var topic: HelpTopic {
    HelpTopic.all.first { $0.id == selectedTopicId } ?? HelpTopic.all[0]
  }

  var body: some View {
    NavigationSplitView {
      // Bound selection rather than a tap gesture, for the same reason as Settings:
      // without it the list highlights nothing and the arrow keys do not move
      // between topics.
      List(HelpTopic.all, selection: $selectedTopicId) { topic in
        Label(topic.title, systemImage: topic.icon)
          .tag(topic.id)
      }
      .navigationSplitViewColumnWidth(min: 180, ideal: 205)
    } detail: {
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          Text(topic.title)
            .font(.title2)
            .fontWeight(.semibold)

          ForEach(Array(topic.blocks.enumerated()), id: \.offset) { pair in
            blockView(pair.element)
          }
        }
        .padding(28)
        // Capped measure, then left-aligned in whatever width is left: prose set
        // across a wide window is hard to read back to the next line.
        .frame(maxWidth: 640, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      // Re-created per topic, so picking a new one starts at the top rather than
      // wherever the previous topic happened to be scrolled to.
      .id(selectedTopicId)
    }
    .frame(minWidth: 720, minHeight: 470)
    .preferredColorScheme(.chat42Override(colorSchemeRaw))
  }

  // MARK: - Blocks

  @ViewBuilder
  private func blockView(_ block: HelpBlock) -> some View {
    switch block {
    case .lead(let key):
      paragraph(key, font: .body)

    case .section(let titleKey, let bodyKey):
      VStack(alignment: .leading, spacing: 6) {
        Text(helpMarkdown(titleKey))
          .font(.headline)
        if let bodyKey {
          paragraph(bodyKey, font: .callout)
        }
      }

    case .terms(let terms):
      VStack(alignment: .leading, spacing: 14) {
        ForEach(terms) { term in
          VStack(alignment: .leading, spacing: 3) {
            Text(helpMarkdown(term.termKey))
              .font(.callout)
              .fontWeight(.medium)
            paragraph(term.detailKey, font: .callout)
          }
        }
      }

    case .shortcuts(let rows):
      VStack(alignment: .leading, spacing: 8) {
        ForEach(rows) { row in
          HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(verbatim: row.keys)
              .font(.system(.callout, design: .monospaced))
              .frame(width: 110, alignment: .leading)
            paragraph(row.detailKey, font: .callout)
          }
          // The keys and what they do are one fact, not two.
          .accessibilityElement(children: .combine)
        }
      }

    case .paths(let rows):
      VStack(alignment: .leading, spacing: 12) {
        ForEach(rows) { row in
          VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: row.path)
              .font(.system(.caption, design: .monospaced))
              .textSelection(.enabled)
              .fixedSize(horizontal: false, vertical: true)
            paragraph(row.detailKey, font: .callout)
          }
          .accessibilityElement(children: .combine)
        }
      }

    case .note(let key):
      HStack(alignment: .top, spacing: 8) {
        Image(systemName: "info.circle")
          .font(.callout)
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
        paragraph(key, font: .callout)
      }
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }
  }

  /// Body prose. `fixedSize` vertically because a `Text` in a `VStack` inside a
  /// `ScrollView` is otherwise free to truncate itself to one line.
  private func paragraph(_ key: String, font: Font) -> some View {
    Text(helpMarkdown(key))
      .font(font)
      .foregroundStyle(.secondary)
      .textSelection(.enabled)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}

// MARK: - Localization

/// Resolves one help string.
///
/// A function rather than a `Text("literal.key")` at each use site: the blocks hold
/// keys as data, so the lookup has to happen where the block is rendered.
private func helpString(_ key: String) -> String {
  String(localized: String.LocalizationValue(key))
}

/// Help prose carries inline markdown — emphasis, and `code` spans for the commands
/// and paths it mentions. Rendered through the same parser the transcript uses, so
/// there is one answer in the app for what markdown means.
private func helpMarkdown(_ key: String) -> AttributedString {
  MessageSegment.attributed(helpString(key))
}

// MARK: - Content model

/// One topic in the Help window.
struct HelpTopic: Identifiable {
  /// Identity in the list. Also the stem the topic's keys are named after, though
  /// `titleKey` still spells its key out — an interpolated key is invisible to the
  /// localization check.
  let id: String
  let icon: String
  let titleKey: String
  let blocks: [HelpBlock]

  var title: String { helpString(titleKey) }
}

/// One renderable piece of a topic.
enum HelpBlock {
  /// Opening paragraph.
  case lead(String)
  /// A subheading, with an optional paragraph under it.
  case section(String, String?)
  /// Rows naming a control or a concept, and saying what it does.
  case terms([HelpTerm])
  /// Key equivalents. The keys themselves are verbatim — ⌘N is not translated.
  case shortcuts([HelpShortcut])
  /// Where something is kept. Paths are verbatim.
  case paths([HelpPath])
  /// An aside worth not missing.
  case note(String)
}

struct HelpTerm: Identifiable {
  /// A term's key is unique within the window, so it doubles as identity.
  var id: String { termKey }
  let termKey: String
  let detailKey: String

  init(_ termKey: String, _ detailKey: String) {
    self.termKey = termKey
    self.detailKey = detailKey
  }
}

struct HelpShortcut: Identifiable {
  var id: String { keys }
  let keys: String
  let detailKey: String

  init(_ keys: String, _ detailKey: String) {
    self.keys = keys
    self.detailKey = detailKey
  }
}

struct HelpPath: Identifiable {
  var id: String { path }
  let path: String
  let detailKey: String

  init(_ path: String, _ detailKey: String) {
    self.path = path
    self.detailKey = detailKey
  }
}

// MARK: - Content

extension HelpTopic {
  /// Every topic, in the order the list shows them: what you need first at the top,
  /// reference material at the bottom.
  static let all: [HelpTopic] = [
    HelpTopic(
      id: "start", icon: "sparkles", titleKey: "help.start.title",
      blocks: [
        .lead("help.start.lead"),
        .section("help.start.first.title", "help.start.first.body"),
        .terms([
          HelpTerm("help.start.step1", "help.start.step1.detail"),
          HelpTerm("help.start.step2", "help.start.step2.detail"),
          HelpTerm("help.start.step3", "help.start.step3.detail"),
          HelpTerm("help.start.step4", "help.start.step4.detail"),
        ]),
        .note("help.start.note"),
      ]),

    HelpTopic(
      id: "backends", icon: "cpu", titleKey: "help.backends.title",
      blocks: [
        .lead("help.backends.lead"),
        .terms([
          HelpTerm("help.backends.ollama", "help.backends.ollama.detail"),
          HelpTerm("help.backends.mlx", "help.backends.mlx.detail"),
          HelpTerm("help.backends.gateway", "help.backends.gateway.detail"),
        ]),
        .note("help.backends.note"),
      ]),

    HelpTopic(
      id: "conversations", icon: "bubble.left.and.bubble.right",
      titleKey: "help.conv.title",
      blocks: [
        .lead("help.conv.lead"),
        .terms([
          HelpTerm("help.conv.new", "help.conv.new.detail"),
          HelpTerm("help.conv.titles", "help.conv.titles.detail"),
          HelpTerm("help.conv.search", "help.conv.search.detail"),
          HelpTerm("help.conv.switch", "help.conv.switch.detail"),
          HelpTerm("help.conv.clear", "help.conv.clear.detail"),
          HelpTerm("help.conv.delete", "help.conv.delete.detail"),
          HelpTerm("help.conv.export", "help.conv.export.detail"),
        ]),
        .note("help.conv.note"),
      ]),

    HelpTopic(
      id: "messages", icon: "text.bubble", titleKey: "help.msg.title",
      blocks: [
        .lead("help.msg.lead"),
        .terms([
          HelpTerm("help.msg.stop", "help.msg.stop.detail"),
          HelpTerm("help.msg.code", "help.msg.code.detail"),
          HelpTerm("help.msg.copy", "help.msg.copy.detail"),
          HelpTerm("help.msg.edit", "help.msg.edit.detail"),
          HelpTerm("help.msg.regenerate", "help.msg.regenerate.detail"),
          HelpTerm("help.msg.retry", "help.msg.retry.detail"),
          HelpTerm("help.msg.delete", "help.msg.delete.detail"),
          HelpTerm("help.msg.images", "help.msg.images.detail"),
        ]),
      ]),

    HelpTopic(
      id: "attachments", icon: "paperclip", titleKey: "help.att.title",
      blocks: [
        .lead("help.att.lead"),
        .terms([
          HelpTerm("help.att.types", "help.att.types.detail"),
          HelpTerm("help.att.limits", "help.att.limits.detail"),
          HelpTerm("help.att.pdf", "help.att.pdf.detail"),
          HelpTerm("help.att.followup", "help.att.followup.detail"),
          HelpTerm("help.att.vision", "help.att.vision.detail"),
        ]),
        .note("help.att.note"),
      ]),

    HelpTopic(
      id: "pinned", icon: "pin", titleKey: "help.pin.title",
      blocks: [
        .lead("help.pin.lead"),
        .terms([
          HelpTerm("help.pin.what", "help.pin.what.detail"),
          HelpTerm("help.pin.add", "help.pin.add.detail"),
          HelpTerm("help.pin.cost", "help.pin.cost.detail"),
          HelpTerm("help.pin.remove", "help.pin.remove.detail"),
        ]),
        .note("help.pin.note"),
      ]),

    HelpTopic(
      id: "compare", icon: "rectangle.split.2x1", titleKey: "help.cmp.title",
      blocks: [
        .lead("help.cmp.lead"),
        .terms([
          HelpTerm("help.cmp.same", "help.cmp.same.detail"),
          HelpTerm("help.cmp.parallel", "help.cmp.parallel.detail"),
          HelpTerm("help.cmp.scope", "help.cmp.scope.detail"),
          HelpTerm("help.cmp.offered", "help.cmp.offered.detail"),
        ]),
      ]),

    HelpTopic(
      id: "presets", icon: "text.badge.star", titleKey: "help.preset.title",
      blocks: [
        .lead("help.preset.lead"),
        .terms([
          HelpTerm("help.preset.start", "help.preset.start.detail"),
          HelpTerm("help.preset.manage", "help.preset.manage.detail"),
          HelpTerm("help.preset.current", "help.preset.current.detail"),
          HelpTerm("help.preset.starters", "help.preset.starters.detail"),
        ]),
      ]),

    HelpTopic(
      id: "quick", icon: "bolt", titleKey: "help.quick.title",
      blocks: [
        .lead("help.quick.lead"),
        .terms([
          HelpTerm("help.quick.menubar", "help.quick.menubar.detail"),
          HelpTerm("help.quick.hotkey", "help.quick.hotkey.detail"),
          HelpTerm("help.quick.service", "help.quick.service.detail"),
        ]),
        .note("help.quick.note"),
      ]),

    HelpTopic(
      id: "context", icon: "speedometer", titleKey: "help.ctx.title",
      blocks: [
        .lead("help.ctx.lead"),
        .terms([
          HelpTerm("help.ctx.trim", "help.ctx.trim.detail"),
          HelpTerm("help.ctx.estimate", "help.ctx.estimate.detail"),
          HelpTerm("help.ctx.cost", "help.ctx.cost.detail"),
          HelpTerm("help.ctx.ollama", "help.ctx.ollama.detail"),
        ]),
      ]),

    HelpTopic(
      id: "settings", icon: "gearshape", titleKey: "help.set.title",
      blocks: [
        .lead("help.set.lead"),
        .terms([
          HelpTerm("help.set.general", "help.set.general.detail"),
          HelpTerm("help.set.presets", "help.set.presets.detail"),
          HelpTerm("help.set.ollama", "help.set.ollama.detail"),
          HelpTerm("help.set.gateway", "help.set.gateway.detail"),
          HelpTerm("help.set.mlx", "help.set.mlx.detail"),
          HelpTerm("help.set.appearance", "help.set.appearance.detail"),
        ]),
        .note("help.set.note"),
      ]),

    HelpTopic(
      id: "shortcuts", icon: "keyboard", titleKey: "help.sc.title",
      blocks: [
        .lead("help.sc.lead"),
        .shortcuts([
          HelpShortcut("⌘N", "help.sc.new"),
          HelpShortcut("⌘E", "help.sc.export"),
          HelpShortcut("⌘F", "help.sc.find"),
          HelpShortcut("⌘R", "help.sc.regen"),
          HelpShortcut("⇧⌘R", "help.sc.refresh"),
          HelpShortcut("⌘1 – ⌘9", "help.sc.jump"),
          HelpShortcut("⌥⌘↓ ⌥⌘↑", "help.sc.cycle"),
          HelpShortcut("↩", "help.sc.send"),
          HelpShortcut("⇧↩", "help.sc.newline"),
          HelpShortcut("⌘,", "help.sc.settings"),
          HelpShortcut("⌘?", "help.sc.help"),
          HelpShortcut("⌃⌥Space", "help.sc.hotkey"),
          HelpShortcut("⌘Q", "help.sc.quit"),
        ]),
      ]),

    HelpTopic(
      id: "privacy", icon: "lock.shield", titleKey: "help.priv.title",
      blocks: [
        .lead("help.priv.lead"),
        .section("help.priv.where", nil),
        .paths([
          HelpPath(
            "~/Library/Application Support/Chat42/conversations.json",
            "help.priv.path.conversations"),
          HelpPath(
            "~/Library/Application Support/Chat42/GeneratedImages/",
            "help.priv.path.images"),
          HelpPath(
            "~/Library/Application Support/Chat42/MLXModels/",
            "help.priv.path.models"),
        ]),
        .terms([
          HelpTerm("help.priv.keychain", "help.priv.keychain.detail"),
          HelpTerm("help.priv.attachments", "help.priv.attachments.detail"),
          HelpTerm("help.priv.local", "help.priv.local.detail"),
          HelpTerm("help.priv.remote", "help.priv.remote.detail"),
        ]),
      ]),

    HelpTopic(
      id: "trouble", icon: "wrench.and.screwdriver", titleKey: "help.tr.title",
      blocks: [
        .lead("help.tr.lead"),
        .terms([
          HelpTerm("help.tr.ollama_down", "help.tr.ollama_down.detail"),
          HelpTerm("help.tr.no_models", "help.tr.no_models.detail"),
          HelpTerm("help.tr.mlx_intel", "help.tr.mlx_intel.detail"),
          HelpTerm("help.tr.mlx_load", "help.tr.mlx_load.detail"),
          HelpTerm("help.tr.gateway_auth", "help.tr.gateway_auth.detail"),
          HelpTerm("help.tr.temperature", "help.tr.temperature.detail"),
          HelpTerm("help.tr.forgotten", "help.tr.forgotten.detail"),
          HelpTerm("help.tr.gatekeeper", "help.tr.gatekeeper.detail"),
        ]),
      ]),
  ]
}
