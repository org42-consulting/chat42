import Foundation

/// One renderable piece of an assistant reply: prose, or a fenced code block.
///
/// Prose arrives pre-rendered as an `AttributedString`. Building it here rather
/// than in the view matters during streaming: the view body is re-evaluated on
/// every flush, and markdown parsing per line per flush was the dominant cost in
/// a long reply.
struct MessageSegment: Identifiable {
  enum Kind {
    case text(AttributedString)
    case code(language: String?, body: String)
  }

  let id: Int
  let kind: Kind

  /// The structural split, before any markdown rendering: prose runs and ```-fenced
  /// blocks, in order.
  enum RawPiece: Equatable {
    case text(String)
    case code(language: String?, body: String)
  }

  /// Splits markdown into prose and ``` fenced blocks. An unterminated fence is
  /// still emitted as a block, so code renders sensibly while a reply streams in.
  static func split(_ content: String) -> [RawPiece] {
    var pieces: [RawPiece] = []
    var textLines: [String] = []
    var codeLines: [String] = []
    var language: String?
    var inCode = false

    func flushText() {
      let joined = textLines.joined(separator: "\n")
      textLines.removeAll()
      guard !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
      pieces.append(.text(joined))
    }
    func flushCode() {
      pieces.append(.code(language: language, body: codeLines.joined(separator: "\n")))
      codeLines.removeAll()
      language = nil
    }

    for line in content.components(separatedBy: "\n") {
      if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
        if inCode {
          flushCode()
          inCode = false
        } else {
          flushText()
          let tag = line.trimmingCharacters(in: .whitespaces).dropFirst(3)
            .trimmingCharacters(in: .whitespaces)
          language = tag.isEmpty ? nil : tag
          inCode = true
        }
        continue
      }
      if inCode { codeLines.append(line) } else { textLines.append(line) }
    }

    if inCode { flushCode() } else { flushText() }
    return pieces
  }

  static func parse(_ content: String) -> [MessageSegment] {
    split(content).enumerated().map { index, piece in
      switch piece {
      case .text(let body):
        return MessageSegment(id: index, kind: .text(attributed(body)))
      case .code(let language, let body):
        return MessageSegment(id: index, kind: .code(language: language, body: body))
      }
    }
  }

  /// Renders inline markdown (emphasis, code spans, links) while keeping the
  /// original line breaks.
  ///
  /// The whole run is parsed in one call. Parsing line by line — the previous
  /// approach — was needed only because the default options collapse newlines;
  /// `.inlineOnlyPreservingWhitespace` keeps them, at one parse instead of one per
  /// line.
  static func attributed(_ markdown: String) -> AttributedString {
    let options = AttributedString.MarkdownParsingOptions(
      interpretedSyntax: .inlineOnlyPreservingWhitespace
    )
    return (try? AttributedString(markdown: markdown, options: options))
      ?? AttributedString(markdown)
  }
}
