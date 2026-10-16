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
codesign --force --sign - "$APP"

echo "已生成 $APP"
