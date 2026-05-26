#!/usr/bin/env bash
# build.sh - Build the Chat42 project

set -eou pipefail

if [ ! -f "Chat42.xcodeproj/project.pbxproj" ]; then
    echo "❌ Xcode project not found. Please ensure you are in the correct directory."
    exit 1
fi

if [ ! -d build ]; then
    mkdir build
fi

# Clean build
echo "Cleaning build..."
xcodebuild -project Chat42.xcodeproj -scheme Chat42 clean

# Build project
echo "Building project..."
xcodebuild -project Chat42.xcodeproj -scheme Chat42 \
    CONFIGURATION_BUILD_DIR="$(pwd)/build" \
    build

if [ $? -eq 0 ]; then
    echo "✅ Build successful!"
else
    echo "❌ Build failed!"
    exit 1
fi

