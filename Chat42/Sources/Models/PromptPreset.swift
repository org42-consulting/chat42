import Foundation

/// A saved way of starting a conversation: instructions plus, optionally, the
/// backend, model, and temperature that suit them.
///
/// The app previously had exactly one global system prompt applied at conversation
/// creation, so every task shared the same instructions. A preset is that prompt
/// made plural and nameable — "code reviewer", "Dutch translator" — which is the
/// difference between retyping context and picking it.
struct PromptPreset: Identifiable, Codable, Hashable {
  var id: UUID
  var name: String
  var systemPrompt: String
  /// Nil means "whatever is currently selected" — a preset about tone need not
  /// pin a model, while one about code probably should.
  var backend: AIBackend?
  var modelName: String?
  var temperature: Double?

  init(
    id: UUID = UUID(),
    name: String,
    systemPrompt: String,
    backend: AIBackend? = nil,
    modelName: String? = nil,
    temperature: Double? = nil
  ) {
    self.id = id
    self.name = name
    self.systemPrompt = systemPrompt
    self.backend = backend
    self.modelName = modelName
    self.temperature = temperature
  }

  /// Decoded leniently so a preset file written by an older build still loads.
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
    name = (try? c.decode(String.self, forKey: .name)) ?? ""
    systemPrompt = (try? c.decode(String.self, forKey: .systemPrompt)) ?? ""
    backend = try? c.decode(AIBackend.self, forKey: .backend)
    modelName = try? c.decode(String.self, forKey: .modelName)
    temperature = try? c.decode(Double.self, forKey: .temperature)
  }

  var displayName: String {
    name.isEmpty ? String(localized: "preset.untitled") : name
  }

  /// A one-line summary of what the preset pins, for the management list.
  var summary: String {
    var parts: [String] = []
    if let backend { parts.append(backend.rawValue) }
    if let modelName, !modelName.isEmpty { parts.append(modelName) }
    if let temperature { parts.append(String(format: "%.2f", temperature)) }
    return parts.isEmpty ? String(localized: "preset.uses_current") : parts.joined(separator: " · ")
  }

  static let starters: [PromptPreset] = [
    PromptPreset(
      name: String(localized: "preset.starter.code_review.name"),
      systemPrompt: String(localized: "preset.starter.code_review.prompt"),
      temperature: 0.2
    ),
    PromptPreset(
      name: String(localized: "preset.starter.translate_nl.name"),
      systemPrompt: String(localized: "preset.starter.translate_nl.prompt"),
      temperature: 0.3
    ),
    PromptPreset(
      name: String(localized: "preset.starter.commit.name"),
      systemPrompt: String(localized: "preset.starter.commit.prompt"),
      temperature: 0.2
    ),
  ]
}

/// Persists presets as JSON in UserDefaults.
///
/// They are small, and keeping them out of `conversations.json` means a corrupt
/// transcript file cannot take the user's saved prompts with it.
enum PresetStore {
  private static let key = "promptPresets"

  static func load() -> [PromptPreset] {
    guard let data = UserDefaults.standard.data(forKey: key),
      let presets = try? JSONDecoder().decode([PromptPreset].self, from: data)
    else { return [] }
    return presets
  }

  static func save(_ presets: [PromptPreset]) {
    guard let data = try? JSONEncoder().encode(presets) else { return }
    UserDefaults.standard.set(data, forKey: key)
  }

  /// True the first time the app runs with presets available, so the starter set
  /// can be seeded once without resurrecting itself after the user deletes them.
  static var hasSeeded: Bool {
    get { UserDefaults.standard.bool(forKey: "promptPresets.seeded") }
    set { UserDefaults.standard.set(newValue, forKey: "promptPresets.seeded") }
  }
}
