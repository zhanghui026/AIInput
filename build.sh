#!/bin/bash
# 构建 AIInput.app
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="AIInput"
BUNDLE_ID="com.zhanghui.aiinput"
BUILD_DIR=".build"
RELEASE_BIN="$BUILD_DIR/release/AIInput"
APP_BUNDLE="$APP_NAME.app"

echo "==> swift build -c release"
swift build -c release

if [ ! -f "$RELEASE_BIN" ]; then
    echo "构建产物未找到: $RELEASE_BIN"
    exit 1
fi

echo "==> 组装 $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$RELEASE_BIN" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
if [ -f "Resources/AppIcon.icns" ]; then
    cp "Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
fi

cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

echo "==> 完成: $APP_BUNDLE"
echo "首次运行请到「系统设置 → 隐私与安全性 → 辅助功能」勾选 $APP_NAME"
