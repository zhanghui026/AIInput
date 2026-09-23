#!/usr/bin/env bash
# 构建 AIInput.app 并打包为 dist/AIInput-<版本>-<提交>.dmg（含拖拽安装用的 Applications 链接）。
# 签名方式沿用 build.sh：设置 AIINPUT_SIGN_IDENTITY 使用证书；否则需显式
# AIINPUT_ALLOW_UNSAFE_ADHOC=1，产物仅适合本机使用，未公证，他人安装会被 Gatekeeper 拦截。
set -euo pipefail

APP_NAME="AIInput"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="$ROOT_DIR/$APP_NAME.app"
DIST_DIR="$ROOT_DIR/dist"

cd "$ROOT_DIR"
"$ROOT_DIR/build.sh"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_BUNDLE/Contents/Info.plist")"
REVISION="$(git rev-parse --short HEAD)"
if ! git diff --quiet HEAD --; then
    REVISION="$REVISION-dirty"
fi
DMG_PATH="$DIST_DIR/$APP_NAME-$VERSION-$REVISION.dmg"

STAGING_DIR="$(mktemp -d)"
trap 'rm -rf "$STAGING_DIR"' EXIT
/usr/bin/ditto "$APP_BUNDLE" "$STAGING_DIR/$APP_NAME.app"
ln -s /Applications "$STAGING_DIR/Applications"

mkdir -p "$DIST_DIR"
rm -f "$DMG_PATH"
echo "==> 打包 $DMG_PATH"
/usr/bin/hdiutil create \
    -volname "$APP_NAME $VERSION" \
    -srcfolder "$STAGING_DIR" \
    -format UDZO \
    -ov \
    "$DMG_PATH" >/dev/null

if [ -n "${AIINPUT_SIGN_IDENTITY:-}" ]; then
    echo "==> 签名 DMG"
    /usr/bin/codesign --force --sign "$AIINPUT_SIGN_IDENTITY" "$DMG_PATH"
fi

echo "==> 校验 DMG"
/usr/bin/hdiutil verify "$DMG_PATH" >/dev/null
echo "==> 完成: $DMG_PATH"
