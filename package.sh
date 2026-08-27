#!/usr/bin/env bash
# package.sh - Package Chat42.app into a DMG, and (optionally) notarize it.
#
# Gatekeeper blocks a downloaded DMG unless the app inside is signed with a
# Developer ID *and* notarized by Apple. Signing alone is not enough: users get
# "Chat42 cannot be opened because Apple cannot check it for malicious software."
# So notarization is part of packaging, not a separate manual step.
#
# Notarization runs when credentials are available, via either:
#   NOTARY_PROFILE=<name>     a profile stored with
#                             `xcrun notarytool store-credentials <name>`
# or:
#   NOTARY_APPLE_ID=<apple-id>
#   NOTARY_TEAM_ID=<team-id>
#   NOTARY_PASSWORD=<app-specific-password>
#
# With neither set, the DMG is still built and the script says plainly that the
# result is not distributable.

set -eou pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Chat42"
# build.sh assembles the bundle under build/ — keep these in step.
APP_BUNDLE="${ROOT}/build/${APP_NAME}.app"
DMG_NAME="${ROOT}/${APP_NAME}.dmg"
STAGING_DIR="$(mktemp -d)"

cleanup() { rm -rf "${STAGING_DIR}"; }
trap cleanup EXIT

if [ ! -d "${APP_BUNDLE}" ]; then
    echo "❌ ${APP_BUNDLE} not found. Run ./build.sh first."
    exit 1
fi

# --- Refuse to ship an ad-hoc signature -------------------------------------
#
# build.sh falls back to ad-hoc signing when no Developer ID is in the keychain.
# That bundle runs locally but cannot be notarized, and shipping it produces the
# Gatekeeper error above. Catch it here rather than after the upload fails.

SIGN_INFO="$(codesign -dv --verbose=4 "${APP_BUNDLE}" 2>&1 || true)"
IS_ADHOC=false
if grep -q "Signature=adhoc" <<<"${SIGN_INFO}"; then
    IS_ADHOC=true
fi

echo "Staging app..."
cp -R "${APP_BUNDLE}" "${STAGING_DIR}/"
ln -s /Applications "${STAGING_DIR}/Applications"

echo "Creating DMG..."
hdiutil create \
    -volname "${APP_NAME}" \
    -srcfolder "${STAGING_DIR}" \
    -ov \
    -format UDZO \
    "${DMG_NAME}"

# --- Notarize ---------------------------------------------------------------

notary_args=()
if [ -n "${NOTARY_PROFILE:-}" ]; then
    notary_args=(--keychain-profile "${NOTARY_PROFILE}")
elif [ -n "${NOTARY_APPLE_ID:-}" ] && [ -n "${NOTARY_TEAM_ID:-}" ] && [ -n "${NOTARY_PASSWORD:-}" ]; then
    notary_args=(--apple-id "${NOTARY_APPLE_ID}" --team-id "${NOTARY_TEAM_ID}" --password "${NOTARY_PASSWORD}")
fi

if [ ${#notary_args[@]} -eq 0 ]; then
    echo "⚠️  No notarization credentials set (NOTARY_PROFILE, or NOTARY_APPLE_ID +"
    echo "    NOTARY_TEAM_ID + NOTARY_PASSWORD)."
    echo "    Created ${DMG_NAME}, but Gatekeeper will refuse it on other Macs."
    exit 0
fi

if [ "${IS_ADHOC}" = true ]; then
    echo "❌ ${APP_BUNDLE} is ad-hoc signed, which cannot be notarized."
    echo "   Install a 'Developer ID Application' identity and re-run ./build.sh."
    exit 1
fi

# The DMG is signed too, so the staple has something to attach to.
if [ -n "${DEVELOPER_ID:-}" ]; then
    codesign --force --sign "${DEVELOPER_ID}" --timestamp "${DMG_NAME}"
else
    DEV_ID="$(security find-identity -v -p codesigning 2>/dev/null \
        | grep -m 1 'Developer ID Application' \
        | sed -E 's/^[[:space:]]*[0-9]+\)[[:space:]]+[A-F0-9]+[[:space:]]+"([^"]+)".*/\1/' || true)"
    if [ -n "${DEV_ID}" ]; then
        codesign --force --sign "${DEV_ID}" --timestamp "${DMG_NAME}"
    fi
fi

echo "Submitting to Apple for notarization (this usually takes a few minutes)..."
xcrun notarytool submit "${DMG_NAME}" "${notary_args[@]}" --wait

echo "Stapling the ticket..."
xcrun stapler staple "${DMG_NAME}"

# Verify the way Gatekeeper will on the user's machine.
echo "Verifying..."
xcrun stapler validate "${DMG_NAME}"
spctl --assess --type open --context context:primary-signature -v "${DMG_NAME}"

echo "✅ Created and notarized ${DMG_NAME}"
