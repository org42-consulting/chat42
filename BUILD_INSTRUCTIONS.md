# Build Instructions for Chat42

## Prerequisites

- Xcode 15 or later
- macOS 13.0 or later
- Apple Silicon Mac (for MLX support)

## Building for App Store

### 1. Code Signing Setup
1. Open the project in Xcode
2. Select the Chat42 target
3. Go to Signing & Capabilities tab
4. Enable "Automatically manage signing"
5. Select your development team
6. Ensure the bundle identifier is set correctly

### 2. Configuration Settings
1. Select "Release" configuration
2. Set deployment target to macOS 13.0
3. Ensure "Code Signing Identity" is set to "Apple Distribution"
4. Verify "Provisioning Profile" is set correctly

### 3. Build Process
1. Clean the project (Product → Clean Build Folder)
2. Build the project (Product → Build)
3. Archive the project (Product → Archive)

### 4. App Store Submission
1. Open Organizer (Window → Organizer)
2. Select the archived project
3. Click "Distribute App"
4. Choose "App Store Connect"
5. Follow the submission wizard

## Release Build Settings

### Required Settings
- Deployment Target: macOS 13.0
- Build Configuration: Release
- Code Signing: Apple Distribution
- Bundle Identifier: com.org42.chat42
- Version Number: 1.0.1
- Build Number: 101

### Optional Settings
- Enable "Strip Debug Symbols During Copy"
- Enable "Generate Debug Symbols"
- Set "Optimization Level" to "Fastest, Smallest [-Oz]"

## Testing Before Submission

Before submitting to the App Store, ensure:
1. All tests pass (TEST_PLAN.md)
2. App icon and screenshots are ready
3. Privacy manifest is complete
4. App description and keywords are prepared
5. No sensitive information is included in logs or code
6. All network connections are secure