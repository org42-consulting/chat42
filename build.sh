#!/usr/bin/env bash
# build.sh - Build the Chat42 project

set -eou pipefail

# Clean build
echo "Cleaning build..."
xcodebuild -project Chat42.xcodeproj -scheme Chat42 clean

# Build project
echo "Building project..."
xcodebuild -project Chat42.xcodeproj -scheme Chat42 \
    CONFIGURATION_BUILD_DIR="$(pwd)" \
    build

if [ $? -eq 0 ]; then
    echo "✅ Build successful!"
else
    echo "❌ Build failed!"
    exit 1
fi

