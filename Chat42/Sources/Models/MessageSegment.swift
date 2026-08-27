import Foundation

/// One renderable piece of an assistant reply: prose, or a fenced code block.
///
/// Text segments are handed to the existing `SelectableText`, which renders
/// markdown line by line, so replies without code blocks render exactly as before.
struct MessageSegment: Identifiable {
  enum Kind {
    case text(String)
    case code(language: String?, body: String)
  }

  let id: Int
  let kind: Kind

  /// Splits markdown into prose and ``` fenced blocks. An unterminated fence is
  /// still emitted as a block, so code renders sensibly while a reply streams in.
  static func parse(_ content: String) -> [MessageSegment] {
    var segments: [MessageSegment] = []
    var textLines: [String] = []
    var codeLines: [String] = []
    var language: String?
    var inCode = false

    func append(_ kind: Kind) {
      segments.append(MessageSegment(id: segments.count, kind: kind))
    }
    func flushText() {
      let joined = textLines.joined(separator: "\n")
      textLines.removeAll()
      guard !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
      append(.text(joined))
    }
    func flushCode() {
      append(.code(language: language, body: codeLines.joined(separator: "\n")))
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
    return segments
  }
}
