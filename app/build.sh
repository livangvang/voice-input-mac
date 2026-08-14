#!/usr/bin/env bash
# 建置「超簡單語音輸入」App，並安裝到 ~/Applications。
#
#   ./build.sh          建置 + 安裝
#   ./build.sh --run    建置 + 安裝 + 開起來
#
# 為什麼是手工組 bundle 而不是 Xcode 專案：這個 App 只有一個 target、沒有資源檔，
# Xcode 專案檔會變成一個沒人看得懂 diff 的 XML。SPM 建出執行檔，這裡把它包成
# .app——整個流程在終端機裡跑得完，也就能被 Claude Code 直接維護。

set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="超簡單語音輸入"
BUNDLE_ID="tw.shadowperformance.voiceinput"
DEST="${HOME}/Applications"
APP="${DEST}/${APP_NAME}.app"

echo "▸ 編譯"
swift build -c release --disable-sandbox

BIN=".build/release/VoiceInputApp"
[ -x "$BIN" ] || { echo "❌ 找不到執行檔 $BIN"; exit 1; }

echo "▸ 組 bundle"
# 先拆掉舊的再建。就地覆蓋的話，macOS 可能還握著舊的 bundle 快取，
# 換了圖示卻不生效就是這樣來的。
rm -rf "$APP"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp "$BIN" "${APP}/Contents/MacOS/${APP_NAME}"

cat > "${APP}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key><string>${APP_NAME}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <!-- 錄音是 sox 在跑，但 sox 是這支 App 的子行程，macOS 把麥克風權限算在
         App 頭上。少了這一行，從 App 按下錄音會被系統直接擋掉且毫無提示。 -->
    <key>NSMicrophoneUsageDescription</key>
    <string>從這裡直接開始錄音時，需要麥克風權限。熱鍵錄音的權限屬於 Hammerspoon，不受這裡影響。</string>
</dict>
</plist>
PLIST

echo "▸ 簽名"
# ad-hoc 簽名（-s -）。本機自用不需要開發者憑證，但**一定要簽**：
# 沒簽名的 app 每次重建都會被 TCC 當成不同的程式，麥克風權限要重按一次。
codesign --force --sign - --identifier "$BUNDLE_ID" "$APP" >/dev/null 2>&1 \
    && echo "  ✅ 已簽名" || echo "  ⚠️  簽名失敗（還是能跑，但權限可能每次重問）"

echo ""
echo "✅ 已安裝：${APP}"

if [ "${1:-}" = "--run" ]; then
    open "$APP"
fi
