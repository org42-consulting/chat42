#!/usr/bin/env bash
# build.sh - Build Chat42.app using only the Xcode Command Line Tools.
#
# Requires: swift, codesign, plutil, iconutil, install_name_tool (all CLT).
# Does NOT require Xcode itself or xcodebuild.

set -eou pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Chat42"
CONFIG="release"

BUILD_DIR="${ROOT}/build"
APP_BUNDLE="${BUILD_DIR}/${APP_NAME}.app"
CONTENTS="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS}/MacOS"
RESOURCES_DIR="${CONTENTS}/Resources"
FRAMEWORKS_DIR="${CONTENTS}/Frameworks"

SRC_RESOURCES="${ROOT}/Chat42/Resources"
ICONSET_SRC="${SRC_RESOURCES}/Assets.xcassets/AppIcon.appiconset"
LOGO_SRC="${SRC_RESOURCES}/Assets.xcassets/org42-logo-text.imageset/org42-logo-text.png"
INFO_SRC="${SRC_RESOURCES}/Info.plist"
PRIVACY_SRC="${SRC_RESOURCES}/PrivacyInfo.xcprivacy"
ENTITLEMENTS="${ROOT}/Chat42/Chat42.entitlements"

# --- Sanity checks ---------------------------------------------------------

if [ ! -f "${ROOT}/Package.swift" ]; then
    echo "❌ Package.swift not found at ${ROOT}/Package.swift"
    exit 1
fi

for tool in swift codesign plutil iconutil install_name_tool; do
    if ! command -v "${tool}" >/dev/null 2>&1; then
        echo "❌ Required tool not found: ${tool}"
        exit 1
    fi
done

# --- Clean -----------------------------------------------------------------

echo "Cleaning build directory..."
rm -rf "${BUILD_DIR}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}" "${FRAMEWORKS_DIR}"

# --- Build the executable via SwiftPM --------------------------------------

echo "Building Swift package (${CONFIG})..."
swift build --package-path "${ROOT}" -c "${CONFIG}"

BIN_PATH="$(swift build --package-path "${ROOT}" -c "${CONFIG}" --show-bin-path)"

if [ ! -f "${BIN_PATH}/${APP_NAME}" ]; then
    echo "❌ Built executable not found at ${BIN_PATH}/${APP_NAME}"
    exit 1
fi

cp "${BIN_PATH}/${APP_NAME}" "${MACOS_DIR}/${APP_NAME}"
chmod +x "${MACOS_DIR}/${APP_NAME}"

# --- Embed dynamic libraries shipped by SwiftPM ----------------------------
#
# MLX (and any other SPM dep that produces a dylib) emits *.dylib files into
# the SwiftPM bin path. To make a self-contained .app, copy them into
# Contents/Frameworks and rewrite the executable's load paths to @rpath.

shopt -s nullglob
DYLIBS=("${BIN_PATH}"/*.dylib)
shopt -u nullglob

if [ ${#DYLIBS[@]} -gt 0 ]; then
    echo "Embedding ${#DYLIBS[@]} dylib(s) from SwiftPM output..."
    for dylib in "${DYLIBS[@]}"; do
        base="$(basename "${dylib}")"
        cp "${dylib}" "${FRAMEWORKS_DIR}/${base}"
        # Rewrite the executable's reference: absolute build-dir path → @rpath
        install_name_tool -change "${dylib}" "@rpath/${base}" \
            "${MACOS_DIR}/${APP_NAME}" 2>/dev/null || true
        # Also handle the case where the load path is just the basename
        install_name_tool -change "${base}" "@rpath/${base}" \
            "${MACOS_DIR}/${APP_NAME}" 2>/dev/null || true
        # And the case where dylibs reference each other by their build path
        for other in "${DYLIBS[@]}"; do
            obase="$(basename "${other}")"
            install_name_tool -change "${other}" "@rpath/${obase}" \
                "${FRAMEWORKS_DIR}/${base}" 2>/dev/null || true
        done
        install_name_tool -id "@rpath/${base}" "${FRAMEWORKS_DIR}/${base}" 2>/dev/null || true
    done
    # Ensure the executable looks in Contents/Frameworks at runtime.
    install_name_tool -add_rpath "@executable_path/../Frameworks" \
        "${MACOS_DIR}/${APP_NAME}" 2>/dev/null || true
fi

# --- Copy SwiftPM resource bundles ----------------------------------------
#
# MLX ships Metal shader libraries inside *.bundle directories that SwiftPM
# emits alongside the executable. They have to sit next to the executable
# (or in Resources) so Bundle(for:) can find them at runtime.

shopt -s nullglob
RBUNDLES=("${BIN_PATH}"/*.bundle)
shopt -u nullglob

if [ ${#RBUNDLES[@]} -gt 0 ]; then
    echo "Copying ${#RBUNDLES[@]} SwiftPM resource bundle(s)..."
    for b in "${RBUNDLES[@]}"; do
        cp -R "${b}" "${RESOURCES_DIR}/"
    done
fi

# --- Info.plist ------------------------------------------------------------

echo "Writing Info.plist..."
cp "${INFO_SRC}" "${CONTENTS}/Info.plist"

# Resolve the build variables that Xcode would normally substitute. Keep
# these in sync with project.yml when changing identifiers or names.
plutil -replace CFBundleDevelopmentRegion -string "en"                 "${CONTENTS}/Info.plist"
plutil -replace CFBundleExecutable        -string "${APP_NAME}"        "${CONTENTS}/Info.plist"
plutil -replace CFBundleIdentifier        -string "com.chat42.Chat42"  "${CONTENTS}/Info.plist"
plutil -replace CFBundleDisplayName       -string "Chat42."            "${CONTENTS}/Info.plist"
plutil -replace CFBundleName              -string "Chat42."            "${CONTENTS}/Info.plist"
plutil -replace NSHumanReadableCopyright  -string "Copyright © 2026 Org42." "${CONTENTS}/Info.plist"
plutil -replace LSMinimumSystemVersion    -string "14.0"               "${CONTENTS}/Info.plist"
plutil -replace CFBundleIconFile          -string "AppIcon"            "${CONTENTS}/Info.plist"

# --- AppIcon.icns (via iconutil, no actool needed) -------------------------

echo "Building AppIcon.icns from iconset..."
TMP_ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "${TMP_ICONSET}"

# Map the existing PNGs in AppIcon.appiconset to the names iconutil expects
# for macOS icns generation. The appiconset stores them by pixel dimension;
# iconutil wants the canonical icon_<point>x<point>[@2x].png naming.
cp "${ICONSET_SRC}/16.png"   "${TMP_ICONSET}/icon_16x16.png"
cp "${ICONSET_SRC}/32.png"   "${TMP_ICONSET}/icon_16x16@2x.png"
cp "${ICONSET_SRC}/32.png"   "${TMP_ICONSET}/icon_32x32.png"
cp "${ICONSET_SRC}/64.png"   "${TMP_ICONSET}/icon_32x32@2x.png"
cp "${ICONSET_SRC}/128.png"  "${TMP_ICONSET}/icon_128x128.png"
cp "${ICONSET_SRC}/256.png"  "${TMP_ICONSET}/icon_128x128@2x.png"
cp "${ICONSET_SRC}/256.png"  "${TMP_ICONSET}/icon_256x256.png"
cp "${ICONSET_SRC}/512.png"  "${TMP_ICONSET}/icon_256x256@2x.png"
cp "${ICONSET_SRC}/512.png"  "${TMP_ICONSET}/icon_512x512.png"
cp "${ICONSET_SRC}/1024.png" "${TMP_ICONSET}/icon_512x512@2x.png"

iconutil -c icns -o "${RESOURCES_DIR}/AppIcon.icns" "${TMP_ICONSET}"
rm -rf "$(dirname "${TMP_ICONSET}")"

# --- Other resources -------------------------------------------------------
#
# The logo PNG goes straight into Resources/ instead of an asset catalog.
# SwiftUI's Image("org42-logo-text") falls back to NSImage(named:), which
# finds top-level images in the main bundle by name.

echo "Copying images and localizations..."
cp "${LOGO_SRC}" "${RESOURCES_DIR}/org42-logo-text.png"

for lang in en nl; do
    mkdir -p "${RESOURCES_DIR}/${lang}.lproj"
    cp "${SRC_RESOURCES}/${lang}.lproj/Localizable.strings" \
       "${RESOURCES_DIR}/${lang}.lproj/Localizable.strings"
done

if [ -f "${PRIVACY_SRC}" ]; then
    cp "${PRIVACY_SRC}" "${RESOURCES_DIR}/PrivacyInfo.xcprivacy"
fi

# --- Code signing ----------------------------------------------------------
#
# Prefer a Developer ID Application identity if one is in the keychain;
# otherwise fall back to ad-hoc ("-"). Ad-hoc is fine for local runs but
# the resulting bundle is not distributable.

echo "Code signing..."
DEV_ID="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -m 1 'Developer ID Application' \
    | sed -E 's/^[[:space:]]*[0-9]+\)[[:space:]]+[A-F0-9]+[[:space:]]+"([^"]+)".*/\1/' || true)"

if [ -n "${DEV_ID}" ]; then
    echo "  Identity: ${DEV_ID}"
    SIGN_FLAGS=(--force --options runtime --timestamp --sign "${DEV_ID}")
else
    echo "  No Developer ID Application identity found — signing ad-hoc."
    SIGN_FLAGS=(--force --sign -)
fi

# Sign embedded code items inside-out before signing the app.
# - Dylibs from SwiftPM are Mach-O and always need a signature.
# - SwiftPM resource bundles (e.g. swift-transformers_Hub.bundle) are usually
#   just data directories with no Info.plist — codesign refuses them and they
#   don't need their own signature. Only sign .bundles that look real.
shopt -s nullglob
for dylib in "${FRAMEWORKS_DIR}"/*.dylib; do
    codesign "${SIGN_FLAGS[@]}" "${dylib}"
done
for bundle in "${RESOURCES_DIR}"/*.bundle; do
    if [ -f "${bundle}/Contents/Info.plist" ] || [ -f "${bundle}/Info.plist" ]; then
        codesign "${SIGN_FLAGS[@]}" "${bundle}"
    fi
done
shopt -u nullglob

codesign "${SIGN_FLAGS[@]}" --entitlements "${ENTITLEMENTS}" "${APP_BUNDLE}"

# --- Done ------------------------------------------------------------------

echo "✅ Build successful: ${APP_BUNDLE}"
