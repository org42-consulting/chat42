# Chat42 Release Notes

## Version 1.0.1

### New Features
- Enhanced privacy manifest for App Store compliance
- Improved error handling for network connections
- Better model loading indicators during downloads
- Updated UI for better accessibility support

### Bug Fixes
- Fixed memory management issues with model loading
- Resolved intermittent connection issues with Ollama backend
- Improved stability when switching between AI backends
- Fixed crash when deleting conversations with streaming responses

### Security
- Added proper privacy manifest file (PrivacyInfo.xcprivacy)
- Enhanced network security for API connections
- Improved code signing configuration for App Store distribution

### Compatibility
- macOS 13.0 or later required
- Apple Silicon (M1/M2/M3/M4/M5) recommended for MLX support
- Full compatibility with Ollama and Gateway backends

## Version 1.0.0

Initial release of Chat42, a native macOS application for local and cloud-based AI model interaction.

### Key Features
- Support for Ollama local inference
- Apple Silicon optimized MLX framework integration
- OpenAI-compatible Gateway API support
- Conversation history persistence
- Dark/light mode support
- Multi-backend switching