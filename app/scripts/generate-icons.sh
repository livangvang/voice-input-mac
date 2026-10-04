#!/usr/bin/env bash
# Generate artwork from the same renderer used by the Dock. Run after changing VoiceLogo.swift.
set -euo pipefail
cd "$(dirname "$0")/.."
ICON_TMP="$(mktemp -d "${TMPDIR:-/tmp/}voice-input-icons.XXXXXX")"
trap 'rm -rf "$ICON_TMP"' EXIT
swiftc Sources/VoiceInputApp/VoiceLogo.swift scripts/export-icons.swift -o "$ICON_TMP/export-icons"
"$ICON_TMP/export-icons" "$ICON_TMP/artwork"
iconutil -c icns "$ICON_TMP/artwork/AppIcon.iconset" -o Assets/AppIcon.icns
cp "$ICON_TMP/artwork/logo.png" Assets/logo.png
# Optional output folder supplies the matching Windows status icons without involving the app runtime.
if [[ -n "${1:-}" ]]; then
    mkdir -p "$1"
    cp "$ICON_TMP/artwork/"*.png "$1/"
fi
