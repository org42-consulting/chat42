import Foundation

/// One text-generating backend.
///
/// All three providers do the same thing from `AppState`'s point of view — take a
/// model name, a context, and a temperature, and hand back tokens — so the send
/// path dispatches through this instead of repeating the same five lines per case.
protocol ChatBackend: Sendable {
  func stream(
    model: String,
    messages: [ChatMessage],
    temperature: Double
  ) async -> AsyncThrowingStream<String, Error>
}

/// Assembles the message list sent to a backend, within a token budget.
enum ContextBuilder {
  /// Rough token estimate. Every provider tokenizes differently and none of them
  /// expose a counter locally, so this deliberately errs on the high side (~4
  /// characters per token) and the budget is treated as advisory.
  static func estimatedTokens(_ text: String) -> Int {
    max(1, text.count / 4)
  }

  static func estimatedTokens(of messages: [ChatMessage]) -> Int {
    messages.reduce(0) { $0 + estimatedTokens($1.content) }
  }

  /// Builds the context for one turn, dropping the oldest turns until the estimate
  /// fits `tokenLimit`.
  ///
  /// System messages are never dropped — they are the instructions, and a budget
  /// small enough to evict them would produce a differently-behaved assistant
  /// rather than a shorter one. The newest turn is never dropped either: a request
  /// trimmed down to no question at all is worse than one that overruns.
  static func build(
    from messages: [Message],
    excluding placeholder: Message?,
    tokenLimit: Int
  ) -> [ChatMessage] {
    let eligible = messages.filter { message in
      if let placeholder, message === placeholder { return false }
      // Never replay our own error text back to the model.
      if message.isError { return false }
      // A cancelled turn can leave an empty assistant message behind; some
      // providers reject empty content outright.
      if message.role == .assistant && message.content.isEmpty { return false }
      return true
    }

    let system = eligible.filter { $0.role == .system }
    let turns = eligible.filter { $0.role != .system }

    var remaining = tokenLimit - system.reduce(0) { $0 + estimatedTokens($1.contextContent) }
    var kept: [Message] = []
    for message in turns.reversed() {
      let cost = estimatedTokens(message.contextContent)
      guard kept.isEmpty || cost <= remaining else { break }
      kept.append(message)
      remaining -= cost
    }

    return (system + kept.reversed()).map { message in
      ChatMessage(
        role: message.role,
        content: message.contextContent,
        images: message.imageDataURIs.isEmpty ? nil : message.imageDataURIs
      )
    }
  }
}
