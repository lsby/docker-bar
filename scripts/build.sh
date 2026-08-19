#!/usr/bin/env bash
set -e

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="DockerBar"
VERSION="1.0.0"
ARCH="$(uname -m)"
OUTPUT_DIR="${PROJECT_ROOT}/dist"
APP_BUNDLE="${OUTPUT_DIR}/${APP_NAME}.app"

echo "🔨 开始构建 ${APP_NAME} v${VERSION} (${ARCH})..."

mkdir -p "${OUTPUT_DIR}"
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

# 编译 Swift 源码
swiftc -O -o "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}" "${PROJECT_ROOT}/src/main.swift"

# 生成 Info.plist
cat << PLIST > "${APP_BUNDLE}/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>com.lsby.DockerBar</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

echo "📦 打包发布产物..."
ZIP_NAME="${APP_NAME}-v${VERSION}-macOS-${ARCH}.zip"
cd "${OUTPUT_DIR}"
rm -f "${ZIP_NAME}"
zip -r -q -y "${ZIP_NAME}" "${APP_NAME}.app"

echo "✅ 构建完成！"
echo "产物路径: ${OUTPUT_DIR}/${ZIP_NAME}"
echo "应用路径: ${APP_BUNDLE}"
