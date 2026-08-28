# Chat42 Release Notes

<!--
  Entries for 1.1.0 through 1.3.1 were reconstructed from commit history: the file
  had been left at 1.0.1 while the bundle version advanced to 1.3.1, so those
  releases shipped with no notes. Keep this file in step with
  CFBundleShortVersionString in Chat42/Resources/Info.plist.
-->

## Version 1.4.1

### Fixed

- **The app no longer hangs at launch behind a Keychain prompt.** `AppState.init`
  read the gateway API key on the main thread before the first frame.
  `SecItemCopyMatching` blocks its thread, and when the keychain ACL does not match
  the running binary macOS answers with a modal password dialog — leaving a frozen
  app with no window to explain why. The ACL stops matching after a re-sign, an OS
  migration, a restore from backup, or any local rebuild. The key is now read after
  the window exists, so a prompt appears over a running app instead of in place of
  one. Settings did the same blocking read on appear; it no longer does.
- Generated image filenames no longer come out as `-.png` for an all-punctuation
  prompt.

### Added

- **Prompt presets.** A preset is a system prompt plus, optionally, the backend,
  model, and temperature that suit it — replacing the single global system prompt
  that applied to every task alike. Managed in Settings → Presets, started from
  File → New Chat from Preset. Three starters ship.
- **Model comparison.** A second model answers every turn and the two replies render
  side by side. Concurrent, so a local model does not have to finish before the
  remote one starts.
- **Retry with a different model**, from the message context menu.
- **Pinned documents** stay in context on every turn, unlike attachments, which the
  model only sees on the turn they arrive.
- **Menu bar item with a quick-ask popover**, backed by a real conversation, so
  anything asked there is in the sidebar afterwards.
- **Global hotkey (⌃⌥Space)** to summon the app. Uses Carbon `RegisterEventHotKey`,
  which needs no Accessibility permission.
- **"Ask Chat42" in the Services menu**, so a selection in any app can start a
  conversation without copy/switch/paste.
- **Context meter** in the composer: tokens used against budget, amber once trimming
  begins. Cost is shown only when a price per million tokens is configured.
- **MLX reloads the last model at launch** (toggleable), instead of starting with
  nothing loaded and a trip through Settings.
- Keyboard: ⌘F focuses search, ⌘1–9 jump to a conversation, ⌘⌥↑/↓ cycle, ⌘E exports.

### Changed

- **The sidebar sorts by recency.** `updatedAt` was maintained and persisted but
  never read for ordering, so a chat replied to minutes ago sat below ones abandoned
  weeks earlier.
- **Search reads the whole transcript**, not just titles, and shows the matching
  snippet under the row.
- The active backend is persisted, so the app reopens where it left off.

### Development

- Integration tests drive the real send pipeline against a recording server
  (`scripts/mock-ollama.py`), verifying at the wire level that an attached document
  is still present on the *second* turn — the regression 1.4.0 was built to fix, and
  previously only checked as a unit test of `ContextBuilder` in isolation.
- `.claude/skills/run-chat42/` adds a driver for launching, driving, and
  screenshotting the app, with the macOS automation traps documented.

## Version 1.4.0

### Fixed

- **Attached files are no longer forgotten after one turn.** Text and PDF contents
  are kept with the message that carried them and replayed on later turns, so a
  follow-up question about a document reaches the model with the document still in
  context. Previously only the turn the file was attached to could see it.
- **Ollama no longer truncates long chats to 4096 tokens.** `num_ctx` had been
  hardcoded, overriding the model's own window; it now follows the new Context size
  setting.
- **Conversation history is trimmed to a token budget** instead of replaying the
  whole transcript every turn. The system prompt and the newest turn are never
  dropped.
- **Dutch errors are actually Dutch.** Ollama, MLX, and attachment failures returned
  hardcoded English while translations for them already existed in the strings
  files but were referenced by nothing. Untitled chats no longer read "New Chat" in
  a Dutch UI, and all eleven MLX model descriptions are now translated.
- **Settings tabs highlight and respond to arrow keys.** The sidebar list had no
  selection binding, so nothing indicated the current pane.
- **MLX downloads keep the repository's directory layout.** Paths were flattened to
  their last component, so a repo shipping `original/model.safetensors` overwrote
  `model.safetensors` and produced a corrupt model. Paths from the file list are
  also now rejected if they try to escape the model directory.
- Generated image filenames no longer come out as `-.png` when the prompt is all
  punctuation.
- Conversations are written atomically, so an interrupted write can no longer leave
  a truncated file that fails to load on next launch.
- Save failures are reported instead of being printed to a console nobody sees.
- A failed Keychain write of the API key is now surfaced rather than silently
  dropped.

### Performance

- **Long replies no longer slow down as they grow.** Tokens are published in
  batches rather than one at a time, prose is parsed once per batch instead of once
  per line per token, and parsed output is cached on the message. Drawing a reply
  used to cost time proportional to the square of its length.
- Scrolling during streaming is no longer animated per update, which removes the
  stutter on long replies.
- Generated images are decoded once, off the main thread, instead of being re-read
  from disk on every redraw.
- Refreshing the model list makes one request instead of two identical ones.
- Model downloads no longer copy every file an extra time before moving it into
  place — a full extra pass over disk for multi-gigabyte weights.
- Conversations are saved on a coalescing timer, off the main thread, instead of
  synchronously after every turn.

### Added

- **Regenerate** the last reply (⌘R), **edit and resend** an earlier message, and
  **delete** individual messages, from the message context menu.
- **Export a conversation as Markdown.**
- **Context size** setting, which also drives Ollama's `num_ctx`.
- **Cancel an in-progress MLX model download** — previously this meant quitting the
  app.
- Attachment size limits (10 MB images, 25 MB documents) with clear errors, and
  truncation of very long extracted text instead of silently sending it all.
- Confirmation before clearing a conversation.

### Changed

- **Each conversation streams independently.** Sending in one chat no longer
  disables the composer in every other chat, and the "generating" indicator appears
  in the chat it belongs to.
- Stopping a reply now tears down the underlying request, so a gateway stops
  generating (and billing) rather than just being ignored.
- Time-to-first-token timeouts raised to 10 minutes: a cold local model or a
  reasoning model routinely exceeded the 60-second default.
- Settings opens one window. The gear button previously presented a second,
  independent copy as a sheet.
- Quitting flushes any pending conversation write.

### Accessibility

- Icon-only buttons (attach, send/stop, refresh, export, clear, copy, regenerate,
  delete model, cancel download) have VoiceOver labels; they previously had
  tooltips only.
- Connection status is exposed as one labelled element rather than a bare coloured
  dot.

### Build, packaging, and privacy

- **`package.sh` notarizes and staples the DMG.** Without this, a downloaded build
  was refused by Gatekeeper with "Apple cannot check it for malicious software". It
  also refuses to notarize an ad-hoc signed bundle rather than producing a DMG that
  cannot be opened.
- **The privacy manifest is accurate.** It previously declared user content and
  identifiers as *collected*, contradicting the stated privacy policy, and used key
  names that are not in Apple's schema. It now declares no collected data and the
  one required-reason API the app actually uses. Invalid required-reason entries
  were removed from `Info.plist`.
- **The two build definitions agree.** `PrivacyInfo.xcprivacy` was missing from the
  Xcode target while `build.sh` shipped it, and strict concurrency checking was
  enabled only in Xcode. Both are now set in both.
- Entitlements are documented, with a separate, ready-to-use MAS entitlements file
  and a note on the Application Support migration a sandboxed build would require.
- **Tests and CI.** 53 unit tests cover markdown segmentation, gateway error
  classification, context trimming, persistence round-trips including legacy files,
  attachment handling, and download path safety. GitHub Actions runs build, test,
  format lint, localization parity, and bundle assembly.

## Version 1.3.1

- `package.sh` reads the app bundle from `build/` to match `build.sh`.

## Version 1.3.0

- Generate images through gateway image models; save code blocks to a file.
- Replaced `xcodebuild` with SwiftPM plus manual bundling, so the app builds with
  only the Command Line Tools installed.
- Omit `temperature` for models that reject it, and surface the gateway's own error
  messages.
- Persist settings correctly, fix deletion against a filtered conversation list, and
  close a `URLSession` delegate leak.

## Version 1.1.0

- Render multi-line AI responses correctly.
- Gateway backend got its own icon; corrected the macOS version in the docs.

## Version 1.0.1

- Added a privacy manifest, improved network error handling, and better model
  loading indicators.

## Version 1.0.0

Initial release of Chat42, a native macOS application for local and cloud-based AI
model interaction.

- Support for Ollama local inference
- Apple Silicon optimized MLX framework integration
- OpenAI-compatible Gateway API support
- Conversation history persistence
- Dark/light mode support
- Multi-backend switching
