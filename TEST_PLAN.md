# Test Plan for Chat42

## Scope

Chat42 ships as a **Developer ID–signed, notarized DMG**, not through the Mac App
Store. This plan covers that channel. The App Sandbox is therefore not required and
is not enabled; `Chat42/Chat42-MAS.entitlements` holds a ready configuration for a
store submission, along with the data-migration work that switch would need first.

Two layers: what CI checks on every push, and what a person has to check by hand
before tagging a release.

## Automated (CI — `.github/workflows/ci.yml`)

Run locally with `swift test`, `swift format lint --recursive --strict Chat42/Sources Tests`,
and `./scripts/check-localization.sh`.

| Area | Covered by |
|---|---|
| Markdown segmentation — fences, unterminated fences during streaming, language tags, ordering | `MessageSegmentTests` |
| Gateway error classification — auth, provider messages, numeric codes, message-less envelopes, the four temperature-rejection phrasings | `GatewayFailureMapperTests` |
| Image vs. chat vs. embedding model routing | `GatewayModelInfoTests` |
| Context trimming — budget, system-prompt and newest-turn preservation, attachment replay, error exclusion | `ContextBuilderTests` |
| Persistence round-trip, legacy files without newer fields, segment cache invalidation | `ConversationPersistenceTests` |
| Attachment extraction, size limits, truncation | `AttachmentProcessorTests` |
| MLX download path resolution and traversal refusal | `MLXDownloadPathTests` |
| en/nl key parity, undefined key references | `scripts/check-localization.sh` |
| Bundle assembles, is signed, ships both localizations and the privacy manifest | `package` job |

**Not covered by tests, and worth knowing:** everything involving a live provider,
the SwiftUI layer, and MLX inference. Those are the manual checks below.

## Manual — before tagging a release

### Backends

- [ ] **Ollama**: models list; a reply streams; stopping mid-reply keeps the partial
      text; with Ollama stopped, the sidebar dot goes red and the error names Ollama.
- [ ] **MLX** (Apple Silicon): download a small model, watch progress, **cancel a
      download mid-flight and confirm it stops**; load; reply streams; unload.
- [ ] **Gateway**: models list; a reply streams; a reasoning-tier model that rejects
      `temperature` still answers (the retry path); an image model returns an image.
- [ ] Switching backends mid-conversation records the model that served each turn.

### The regressions this release fixes

- [ ] Attach a PDF, ask about it, then ask a **follow-up** — the model still knows
      the contents.
- [ ] Send a long chat to Ollama and confirm early turns are not silently lost at
      4096 tokens.
- [ ] Start a reply in chat A, switch to chat B, and **type and send there** while A
      is still streaming.
- [ ] Ask for a long reply (~1000 words) and confirm it renders smoothly to the end.
- [ ] Regenerate; edit-and-resend an earlier message; delete a single message.
- [ ] Export a conversation to Markdown and reopen it.
- [ ] Quit mid-conversation, relaunch, confirm the last turn is there.

### Localization

- [ ] Run the app in Dutch (`Chat42.app/Contents/MacOS/Chat42 -AppleLanguages '(nl)'`).
- [ ] Stop Ollama and confirm the error is **Dutch**, not English.
- [ ] Untitled chats are not labelled "New Chat".
- [ ] MLX model descriptions are translated.

### Accessibility

- [ ] VoiceOver announces every toolbar and composer button by name.
- [ ] The whole send flow is reachable by keyboard alone.
- [ ] Settings panes change with arrow keys and the current pane is highlighted.
- [ ] Connection status is understandable without seeing colour.

### Packaging

- [ ] `./build.sh` with a Developer ID in the keychain reports that identity, not
      ad-hoc.
- [ ] `./package.sh` with notary credentials completes and staples.
- [ ] `xcrun stapler validate Chat42.dmg` passes.
- [ ] **Install from the DMG on a Mac that has never seen the app** — the real
      Gatekeeper test, and the one an un-notarized build fails.
- [ ] `codesign -dv --verbose=4 Chat42.app` shows the hardened runtime enabled.

### Sanity

- [ ] Launches on a clean macOS 14 install.
- [ ] Memory is stable across a long conversation and does not climb per token.
- [ ] Deleting a conversation with generated images removes the image files.
- [ ] An oversized attachment is refused with a clear message rather than uploaded.
