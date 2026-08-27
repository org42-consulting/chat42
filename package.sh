#!/usr/bin/env bash
# package.sh - Package Chat42.app into a DMG

set -eou pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Chat42"
# build.sh assembles the bundle under build/ — keep these in step.
APP_BUNDLE="${ROOT}/build/${APP_NAME}.app"
DMG_NAME="${ROOT}/${APP_NAME}.dmg"
STAGING_DIR="$(mktemp -d)"

if [ ! -d "${APP_BUNDLE}" ]; then
    echo "❌ ${APP_BUNDLE} not found. Run ./build.sh first."
    exit 1
fi

echo "Staging app..."
cp -r "${APP_BUNDLE}" "${STAGING_DIR}/"
ln -s /Applications "${STAGING_DIR}/Applications"

echo "Creating DMG..."
hdiutil create \
    -volname "${APP_NAME}" \
    -srcfolder "${STAGING_DIR}" \
    -ov \
    -format UDZO \
    "${DMG_NAME}"

rm -rf "${STAGING_DIR}"

echo "✅ Created ${DMG_NAME}"
