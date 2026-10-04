#!/usr/bin/env bash
# Build an isolated universal candidate by default; --install explicitly replaces the installed app.
set -euo pipefail
cd "$(dirname "$0")"
VERSION="${VOICE_INPUT_VERSION:-1.1.11}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Invalid version'; exit 1; }
OUTPUT="${VOICE_INPUT_OUTPUT:-$PWD/dist}"
SCRATCH="${VOICE_INPUT_SCRATCH:-$PWD/.build-universal}"
APP_NAME="超簡單語音輸入"
BUNDLE_ID="tw.shadowperformance.voiceinput"
APP="$OUTPUT/$APP_NAME.app"
MODE="${1:---candidate}"
mkdir -p "$OUTPUT"
swift build -c release --arch arm64 --arch x86_64 --scratch-path "$SCRATCH" --disable-sandbox
BIN_DIR="$(swift build -c release --arch arm64 --arch x86_64 --scratch-path "$SCRATCH" --show-bin-path)"
[[ -x "$BIN_DIR/VoiceInputApp" ]] || { echo 'Missing executable'; exit 1; }
[[ "$APP" == "$OUTPUT/$APP_NAME.app" && -n "$OUTPUT" && "$OUTPUT" != / ]] || exit 1
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/VoiceInputApp" "$APP/Contents/MacOS/$APP_NAME"
cp "Assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp -R "Assets/Sounds" "$APP/Contents/Resources/Sounds"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>$APP_NAME</string>
<key>CFBundleDisplayName</key><string>$APP_NAME</string>
<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
<key>CFBundleExecutable</key><string>$APP_NAME</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$VERSION</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSMicrophoneUsageDescription</key><string>將你說的話轉成文字，需要使用麥克風。</string>
</dict></plist>
PLIST
cat > "$OUTPUT/audio.entitlements" <<PLIST
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>com.apple.security.device.audio-input</key><true/></dict></plist>
PLIST
SIGNING="${VOICE_INPUT_SIGNING_IDENTITY:--}"
if [[ "$MODE" == --release ]]; then
    [[ "$SIGNING" == 'Developer ID Application:'* ]] || { echo 'A Developer ID Application identity is required'; exit 1; }
    [[ -n "${VOICE_INPUT_NOTARY_PROFILE:-}" ]] || { echo 'A notarytool Keychain profile is required'; exit 1; }
fi
if [[ "$SIGNING" == - ]]; then
    codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
else
    codesign --force --sign "$SIGNING" --timestamp --options runtime --entitlements "$OUTPUT/audio.entitlements" "$APP"
fi
codesign --verify --deep --strict "$APP"
lipo -archs "$APP/Contents/MacOS/$APP_NAME"
STAGE="$OUTPUT/dmg-stage"
mkdir -p "$STAGE"
rm -rf "$STAGE/$APP_NAME.app"
cp -R "$APP" "$STAGE/$APP_NAME.app"
ln -sfn /Applications "$STAGE/Applications"
printf '%s\n' '將 App 拖入 Applications，開啟後依引導配對。先連上 Tailscale。' > "$STAGE/開始使用.txt"
DMG="$OUTPUT/VoiceInput-$VERSION-macos-universal.dmg"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
if [[ "$MODE" == --release ]]; then
    codesign --sign "$SIGNING" --timestamp "$DMG"
    xcrun notarytool submit "$DMG" --keychain-profile "$VOICE_INPUT_NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
    spctl --assess --type open --context context:primary-signature "$DMG"
fi
VOICE_BUILD_OUTPUT="$OUTPUT" VOICE_BUILD_VERSION="$VERSION" VOICE_BUILD_DMG="$DMG" VOICE_BUILD_SIGNED="$MODE" /usr/bin/python3 - <<'PY'
import hashlib,json,os,pathlib,subprocess
p=pathlib.Path(os.environ['VOICE_BUILD_DMG'])
data={'platform':'mac','version':os.environ['VOICE_BUILD_VERSION'],'architecture':'arm64+x86_64','minimum_os':'macOS 14+','filename':p.name,'sha256':hashlib.sha256(p.read_bytes()).hexdigest(),'source':subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),'dirty':bool(subprocess.check_output(['git','status','--porcelain'],text=True).strip()),'status':'candidate','signed':os.environ['VOICE_BUILD_SIGNED']=='--release'}
(pathlib.Path(os.environ['VOICE_BUILD_OUTPUT'])/'candidate.json').write_text(json.dumps(data,ensure_ascii=False,indent=2))
PY
if [[ "$MODE" == --install || "$MODE" == --run ]]; then
    DEST="$HOME/Applications/$APP_NAME.app"
    mkdir -p "$HOME/Applications"
    if [[ -d "$DEST" ]]; then mv "$DEST" "$DEST.pre-native-$(date +%Y%m%d%H%M%S).bak"; fi
    cp -R "$APP" "$DEST"
    if [[ "$MODE" == --run ]]; then open "$DEST"; fi
fi
printf 'Built candidate: %s\n' "$DMG"
