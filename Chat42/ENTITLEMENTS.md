# Entitlements

Two files, one per distribution channel. Neither carries inline comments: the
parser `codesign --entitlements` uses (`AMFIUnserializeXML`) rejects XML comments
outright — a commented entitlements file fails signing with
`syntax error near line N`. Hence this file.

## `Chat42.entitlements` — the shipping channel

Developer ID + notarized DMG. **Deliberately empty.**

The app runs under the hardened runtime (`build.sh` signs with `--options runtime`),
which is what notarization requires. Outside the App Sandbox an app already has
network access and can read the files a user picks in an open panel, so no
entitlement here would grant anything the app does not already have. Every
entitlement weakens the runtime, so none are set.

## `Chat42-MAS.entitlements` — a Mac App Store submission

Not used by `build.sh`. It sets:

| Entitlement | Why |
|---|---|
| `com.apple.security.app-sandbox` | Required for the store |
| `com.apple.security.network.client` | Ollama, the Gateway, Hugging Face downloads |
| `com.apple.security.files.user-selected.read-write` | Attachments come from an open panel; exports, generated images, and code snippets go out through a save panel |

### Read this before switching to it

**Enabling the sandbox relocates the app's data and strands what is already there.**
Today conversations live at

    ~/Library/Application Support/Chat42/conversations.json

and MLX weights at

    ~/Library/Application Support/Chat42/MLXModels/

Under the sandbox those paths resolve inside
`~/Library/Containers/com.chat42.Chat42/Data/…`. An existing user updating to a
sandboxed build opens an empty app: every conversation and every downloaded model
appears to be gone, including tens of gigabytes of weights they would have to
fetch again.

Shipping this without a one-time migration that copies the old directory into the
container is a data-loss bug, not a packaging change. The migration has to run
before `AppState.init` reads `conversations.json` and before `MLXService` restores
`modelURLs` from `UserDefaults` — both of which happen at launch.

Two further consequences worth checking before submitting:

- **Ollama on localhost.** The sandbox permits outbound connections with
  `network.client`, but a store reviewer has no Ollama running, so that backend
  cannot be demonstrated. MLX and Gateway can.
- **Model storage.** Multi-gigabyte downloads land in the container, which is
  treated differently by Time Machine and iCloud backup than the current location.
