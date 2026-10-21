#!/bin/zsh
# 编译命令行 buds 和菜单栏 App「小米耳机」
set -e
cd "$(dirname "$0")"
mkdir -p build
swiftc -O Shared/*.swift CLI/main.swift -o build/buds
ln -sf "$PWD/build/buds" ~/.local/bin/buds
echo "命令行：$PWD/build/buds"

# 菜单栏 App：编译成 .app，装到 /Applications
APP=build/Buds.app
rm -rf $APP
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
swiftc -O -parse-as-library Shared/*.swift App/Model.swift App/BudsApp.swift -o $APP/Contents/MacOS/Buds
cp App/Info.plist $APP/Contents/
cp App/Resources/AppIcon.icns $APP/Contents/Resources/
codesign --force --sign - $APP
pkill -x Buds 2>/dev/null || true
rm -rf /Applications/Buds.app
cp -R $APP /Applications/
echo "App：/Applications/Buds.app"
