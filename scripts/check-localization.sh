#!/usr/bin/env bash
# check-localization.sh — guard the en/nl Localizable.strings invariants.
#
# Three ways these files go wrong, all of which ship a broken string to a user:
#   1. A key exists in one language and not the other  → untranslated UI.
#   2. Code asks for a key that no .strings file defines → the raw key is drawn
#      on screen ("settings.tab.general" instead of "General").
#   3. A key is defined but nothing references it → dead weight that hides which
#      strings are actually live.
#
# (3) is reported but does not fail the build: keys referenced dynamically, or via
# a plain `Text("some.key")` literal, are legitimately invisible to this grep.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EN="${ROOT}/Chat42/Resources/en.lproj/Localizable.strings"
NL="${ROOT}/Chat42/Resources/nl.lproj/Localizable.strings"
SOURCES="${ROOT}/Chat42/Sources"

fail=0
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

keys_of() {
    grep -oE '^"[^"]+"' "$1" | tr -d '"' | sort -u
}

keys_of "${EN}" >"${tmp}/en.txt"
keys_of "${NL}" >"${tmp}/nl.txt"

# --- 1. Key-set parity ------------------------------------------------------

if ! diff -q "${tmp}/en.txt" "${tmp}/nl.txt" >/dev/null; then
    echo "❌ en/nl key sets differ:"
    comm -23 "${tmp}/en.txt" "${tmp}/nl.txt" | sed 's/^/     only in en: /'
    comm -13 "${tmp}/en.txt" "${tmp}/nl.txt" | sed 's/^/     only in nl: /'
    fail=1
else
    echo "✅ en/nl key sets match ($(wc -l <"${tmp}/en.txt" | tr -d ' ') keys)"
fi

# --- 2. Keys referenced from code but never defined -------------------------
#
# Covers String(localized: "…"), Text("…"), and LocalizationValue("…"). Anything
# that looks like a dotted lowercase identifier in a string literal is treated as
# a candidate key.

grep -rhoE '"[a-z][a-z0-9_]*(\.[a-z0-9_]+)+"' "${SOURCES}" \
    | tr -d '"' | sort -u >"${tmp}/referenced.txt"

# Only consider references that look like our namespaces, so file names, URLs, and
# MIME types do not produce noise.
grep -E '^(alert|attachment|chat|code|default|error|export|help|image|input|menu|message|mlx|model|preset|quick|service|settings|sidebar)\.' \
    "${tmp}/referenced.txt" >"${tmp}/candidates.txt" || true

missing="$(comm -23 "${tmp}/candidates.txt" "${tmp}/en.txt" || true)"
if [ -n "${missing}" ]; then
    echo "❌ referenced in code but not defined in en.lproj:"
    echo "${missing}" | sed 's/^/     /'
    fail=1
else
    echo "✅ every referenced key is defined"
fi

# --- 3. Defined but unreferenced (advisory) ---------------------------------

unused="$(comm -13 "${tmp}/candidates.txt" "${tmp}/en.txt" || true)"
if [ -n "${unused}" ]; then
    echo "ℹ️  defined but not referenced (check before deleting — some are used dynamically):"
    echo "${unused}" | sed 's/^/     /'
fi

exit "${fail}"
