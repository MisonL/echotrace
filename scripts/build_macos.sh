#!/bin/bash
# EchoTrace macOS 一键构建脚本
# 用法: ./scripts/build_macos.sh [debug|release]

set -e

MODE="${1:-debug}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_DIR"

echo "🔨 EchoTrace macOS 构建"
echo "========================"
echo "模式: $MODE"
echo ""

# 清理旧构建
echo "🧹 清理旧构建..."
rm -rf build/macos

# 安装依赖
echo "📦 安装依赖..."
~/flutter/bin/flutter pub get

# 构建
echo "🔨 开始构建..."
if [ "$MODE" = "release" ]; then
    ~/flutter/bin/flutter build macos --release 2>&1
else
    ~/flutter/bin/flutter build macos --debug 2>&1
fi

# 后处理
echo ""
echo "📂 后处理..."
./scripts/macos_post_build.sh

# 复制到桌面
echo ""
echo "📋 复制到桌面..."
rm -rf ~/Desktop/echotrace.app
cp -R "build/macos/Build/Products/$([ "$MODE" = "release" ] && echo "Release" || echo "Debug")/echotrace.app" ~/Desktop/

echo ""
echo "========================"
echo "✅ 构建完成！"
echo "应用位置: ~/Desktop/echotrace.app"
