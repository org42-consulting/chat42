# File Upload Design

**Date:** 2026-05-08  
**Status:** Approved  
**Feature:** Attach files (text, images, PDF) to chat messages

---

## Overview

Users can attach files to any outgoing message. Attached files are processed at send-time and injected into the API payload as context. Raw file bytes are never persisted — only lightweight display metadata is stored alongside the message.

---

## Supported File Types

| Type | Extensions | How it's sent |
|---|---|---|
| Text / source | Any file whose `UTType` conforms to `.text` (covers `.txt`, `.md`, `.swift`, `.py`, `.js`, `.ts`, `.json`, `.yaml`, `.sh`, etc.) | Content extracted as UTF-8, prepended to message as a labeled block |
| Image | `.png`, `.jpg`, `.jpeg`, `.webp`, `.gif` | Base64-encoded, sent via native multimodal API format |
| PDF | `.pdf` | Text extracted via PDFKit, prepended to message as a labeled block |

---

## Data Model

### `AttachmentType` (new)
```swift
enum AttachmentType: String, Codable {
    case text, image, pdf
}
```

### `AttachedFile` (new — transient, never persisted)
Holds a staged file while the user is composing a message.

```swift
struct AttachedFile: Identifiable {
    let id: UUID
    let url: URL
    let name: String
    let type: AttachmentType
    let data: Data
}
```

### `MessageAttachment` (new — Codable, stored on `Message`)
Lightweight display record only. No bytes.

```swift
struct MessageAttachment: Codable, Identifiable {
    let id: UUID
    let name: String
    let type: AttachmentType
}
```

### `Message` changes
Add `var attachments: [MessageAttachment] = []`. `MessageDTO` mirrors this field for persistence.

---

## Processing & API Layer

### `AttachmentProcessor` (new — `Services/AttachmentProcessor.swift`)

Stateless. Responsible for:
- **Text/source**: read as UTF-8, wrap as:
  ```
  [File: filename.swift]
  <content>
  ---
  ```
- **PDF**: extract full text via `PDFKit.PDFDocument`, same wrapping
- **Images**: encode `Data` → base64 string, return separately for multimodal payload

### Per-backend behaviour

| Backend | Text / PDF | Images |
|---|---|---|
| **Ollama** | Prepend extracted text to `content` string | Pass as `"images": [base64string]` on the user message |
| **Gateway** | Prepend text block inside a `text` content part | Build OpenAI multimodal `content` array: `[{type:"text",...}, {type:"image_url", image_url:{url:"data:image/png;base64,..."}}]` |
| **MLX** | Prepend text block to content string | Show error: "MLX does not support image attachments" |

### `GatewayChatMessage` content shape change

`content` changes from `String` to a `ContentPayload` enum:

```swift
enum ContentPayload: Encodable {
    case text(String)
    case parts([ContentPart])
}

struct ContentPart: Encodable {
    let type: String           // "text" or "image_url"
    let text: String?
    let imageURL: ImageURL?    // CodingKey: "image_url"
}

struct ImageURL: Encodable {
    let url: String            // "data:image/png;base64,..."
}
```

### `OllamaChatMessage` change

Add `var images: [String]?` (base64 strings). Nil when no images are attached.

### `AppState.sendMessage` signature change

```swift
func sendMessage(_ text: String, attachments: [AttachedFile] = []) async
```

---

## UI Layer

### `ChatInputView` changes

- **Paperclip button** on the left of the text field — opens `NSOpenPanel` with allowed content types
- **Drop target** on the entire input area via `.onDrop(of: [.fileURL])` — accepts dragged files
- **`AttachmentRowView`** appears above the text field when `pendingAttachments` is non-empty
- `canSend` is true when input text is non-empty **or** pending attachments are non-empty

Layout:
```
┌─────────────────────────────────────────┐
│ 📎 [main.swift ×] [photo.png ×]         │  ← AttachmentRowView (visible only when files staged)
├─────────────────────────────────────────┤
│ 📎  [ type your message...         ] ↑  │  ← paperclip | GrowingTextView | send
└─────────────────────────────────────────┘
```

### New views

**`AttachmentRowView`** — horizontally scrolling row of `AttachmentChipView` chips, shown above the text input when files are staged.

**`AttachmentChipView`** — displays a single staged attachment:
- SF Symbol icon for type (`doc.text`, `photo`, `doc.richtext`)
- Truncated filename
- × button to remove from pending list

### `ChatView` state changes

```swift
@State var pendingAttachments: [AttachedFile] = []
```

`sendMessage()` passes both `inputText` and `pendingAttachments` to `AppState`, then clears both.

### `MessageBubbleView` changes

When `message.attachments` is non-empty, render a read-only row of chips above the bubble text (same `AttachmentChipView` but without the × button).

---

## Error Handling

| Scenario | Behaviour |
|---|---|
| Image attached with MLX backend | Error message in assistant bubble: "MLX does not support image attachments" |
| PDF text extraction fails | Error message in assistant bubble: "Could not extract text from \<filename\>" |
| File is unreadable (permissions, corrupt) | Show a brief `NSAlert`, do not add chip |
| Unsupported file type dropped | Silently ignore (no chip added) |

---

## Out of Scope

- Re-attaching files from previous messages
- Storing file bytes on disk
- File size limits (left to the backend to enforce)
- Multiple image support for MLX (future: when MLX gains vision capability)
