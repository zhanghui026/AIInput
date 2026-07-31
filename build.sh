#!/bin/bash
# 构建 AIInput.app
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="AIInput"
BUNDLE_ID="com.zhanghui.aiinput"
BUILD_DIR=".build"
RELEASE_BIN="$BUILD_DIR/release/AIInput"
APP_BUNDLE="$APP_NAME.app"
DEVELOPMENT_MARKER_KEY="AIInputDevelopmentSignatureMarker"
DEVELOPMENT_MARKER_VALUE="com.zhanghui.aiinput.local-development.v1"
CHECK_STABLE_DR=false

case "${1:-}" in
    "")
        ;;
    --check-stable-dr)
        CHECK_STABLE_DR=true
        ;;
    *)
        echo "用法: $0 [--check-stable-dr]" >&2
        exit 2
        ;;
esac

find_signing_identity() {
    if [ -n "${AIINPUT_SIGN_IDENTITY:-}" ]; then
        printf '%s\n' "$AIINPUT_SIGN_IDENTITY"
        return
    fi

    /usr/bin/security find-identity -v -p codesigning 2>/dev/null \
        | /usr/bin/sed -nE 's/^[[:space:]]*[0-9]+\) ([[:xdigit:]]{40}) .*/\1/p' \
        | /usr/bin/sed -n '1p'
}

SIGN_IDENTITY="$(find_signing_identity)"
if [ "$SIGN_IDENTITY" = "-" ]; then
    SIGN_IDENTITY=""
fi

ADHOC_DESIGNATED_REQUIREMENT="designated => identifier \"$BUNDLE_ID\" and info[$DEVELOPMENT_MARKER_KEY] = \"$DEVELOPMENT_MARKER_VALUE\""

build_app() {
    echo "==> swift build -c release"
    swift build -c release

    if [ ! -f "$RELEASE_BIN" ]; then
        echo "构建产物未找到: $RELEASE_BIN" >&2
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
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>${DEVELOPMENT_MARKER_KEY}</key>
    <string>${DEVELOPMENT_MARKER_VALUE}</string>
</dict>
</plist>
PLIST

    if [ -n "$SIGN_IDENTITY" ]; then
        echo "==> 使用代码签名身份: $SIGN_IDENTITY"
        /usr/bin/codesign --force \
            --identifier "$BUNDLE_ID" \
            --sign "$SIGN_IDENTITY" \
            "$APP_BUNDLE"
    else
        echo "警告: 未找到代码签名身份，使用仅限本机开发的稳定 ad-hoc requirement。" >&2
        echo "警告: 此 requirement 没有证书锚点，可被同机恶意程序仿冒；请勿用于分发。" >&2
        echo "提示: 设置 AIINPUT_SIGN_IDENTITY 可改用钥匙串中的正式代码签名身份。" >&2
        /usr/bin/codesign --force \
            --identifier "$BUNDLE_ID" \
            --requirements "=$ADHOC_DESIGNATED_REQUIREMENT" \
            --sign - \
            "$APP_BUNDLE"
    fi

    echo "==> 验证代码签名"
    /usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
}

designated_requirement() {
    /usr/bin/codesign -d -r- "$APP_BUNDLE" 2>&1 \
        | /usr/bin/sed -n '/^designated => /p'
}

build_app

if $CHECK_STABLE_DR; then
    first_requirement="$(designated_requirement)"
    if [ -z "$first_requirement" ]; then
        echo "无法读取第一次构建的 designated requirement" >&2
        exit 1
    fi

    build_app
    second_requirement="$(designated_requirement)"
    if [ "$first_requirement" != "$second_requirement" ]; then
        echo "designated requirement 在连续构建间发生变化:" >&2
        echo "第一次: $first_requirement" >&2
        echo "第二次: $second_requirement" >&2
        exit 1
    fi
    echo "==> designated requirement 连续两次构建保持稳定"
    echo "$second_requirement"
fi

echo "==> 完成: $APP_BUNDLE"
echo "自动粘贴首次使用时，请在「系统设置 → 隐私与安全性 → 辅助功能」中授权 $APP_NAME"
