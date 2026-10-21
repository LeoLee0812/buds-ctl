#!/bin/zsh
# 编译 buds 命令行工具，并在 ~/.local/bin 里放一个软链
set -e
cd "$(dirname "$0")"
swiftc -O main.swift -o buds
ln -sf "$PWD/buds" ~/.local/bin/buds
echo "已编译：$PWD/buds"
