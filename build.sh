#!/bin/bash
# MultiOut 一键构建脚本：swiftc 编译 + 组装 .app bundle + ad-hoc 签名
#
# 环境变量：
#   ARCHES                 目标架构，默认 "arm64"；CI 里用 "arm64 x86_64" 出通用二进制
#   MACOSX_DEPLOYMENT_TARGET  最低系统版本，默认 13.0
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="MultiOut"
BUILD_DIR="build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
ARCHES="${ARCHES:-arm64}"
DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-13.0}"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"

echo "==> 编译 Swift 源码（架构: ${ARCHES}，部署目标: ${DEPLOYMENT_TARGET}）..."
BINARIES=()
for arch in $ARCHES; do
    out="$BUILD_DIR/.MultiOut-$arch"
    swiftc -O -swift-version 5 \
        -target "$arch-apple-macos$DEPLOYMENT_TARGET" \
        -module-name MultiOut \
        -o "$out" \
        Sources/*.swift
    BINARIES+=("$out")
done

if [ "${#BINARIES[@]}" -gt 1 ]; then
    echo "==> lipo 合并通用二进制..."
    lipo -create "${BINARIES[@]}" -output "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
    rm -f "${BINARIES[@]}"
else
    mv "${BINARIES[0]}" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
fi

echo "==> 组装 App Bundle..."
cp Info.plist "$APP_BUNDLE/Contents/Info.plist"

echo "==> Ad-hoc 签名..."
codesign --force --sign - "$APP_BUNDLE" >/dev/null 2>&1

echo "==> 完成: $PWD/$APP_BUNDLE"
echo "    运行:      open $APP_BUNDLE"
echo "    自检模式:  $APP_BUNDLE/Contents/MacOS/$APP_NAME --selftest"
