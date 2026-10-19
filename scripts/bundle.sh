#!/bin/zsh
# 编译 release 版本并打包成 build/Transory.app（ad-hoc 签名，仅供本机使用）。
set -euo pipefail

cd "$(dirname "$0")/.."
swift build -c release

APP=build/Transory.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/Transory" "$APP/Contents/MacOS/Transory"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# 图标由 scripts/make-icon.swift 生成；改了图标后重新运行它。
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"

echo "已生成 $APP"
