#!/bin/zsh
# 打发布包：arm64 + x86_64 通用二进制的 Buds.app 和 buds 命令行，输出到 dist/
set -e
cd "$(dirname "$0")"
VERSION=${1:-1.0.0}
rm -rf dist && mkdir -p dist/tmp

build() {
    # $1 输出路径，其余是源文件
    local out=$1; shift
    for arch in arm64 x86_64; do
        swiftc -O -target $arch-apple-macos14.0 "$@" -o dist/tmp/$(basename $out)-$arch
    done
    lipo -create dist/tmp/$(basename $out)-arm64 dist/tmp/$(basename $out)-x86_64 -output $out
}

APP=dist/Buds.app
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
build $APP/Contents/MacOS/Buds -parse-as-library Shared/*.swift App/Model.swift App/BudsApp.swift
sed "s#<string>1.0</string>#<string>$VERSION</string>#" App/Info.plist > $APP/Contents/Info.plist
cp App/Resources/AppIcon.icns $APP/Contents/Resources/
codesign --force --sign - $APP

build dist/buds Shared/*.swift CLI/main.swift
codesign --force --sign - dist/buds

(cd dist && ditto -c -k --keepParent Buds.app Buds-$VERSION-macOS.zip && zip -q buds-cli-$VERSION-macOS.zip buds)
rm -rf dist/tmp
ls -la dist
