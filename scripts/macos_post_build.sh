#!/bin/bash
# EchoTrace macOS 构建后处理脚本
# 用于复制 Go 解密库到应用包中

set -e

APP_PATH="$1"
if [ -z "$APP_PATH" ]; then
    APP_PATH="build/macos/Build/Products/Debug/echotrace.app"
fi

FRAMEWORKS_DIR="$APP_PATH/Contents/Frameworks"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

echo "📦 EchoTrace macOS 后处理脚本"
echo "================================"
echo "应用路径: $APP_PATH"
echo "项目路径: $PROJECT_DIR"

# 确保 Frameworks 目录存在
mkdir -p "$FRAMEWORKS_DIR"

# 复制 dylib 文件
echo ""
echo "📂 复制 Go 解密库..."

if [ -f "$PROJECT_DIR/assets/dll/libgo_decrypt_x64.dylib" ]; then
    cp "$PROJECT_DIR/assets/dll/libgo_decrypt_x64.dylib" "$FRAMEWORKS_DIR/"
    echo "  ✅ libgo_decrypt_x64.dylib"
else
    echo "  ❌ libgo_decrypt_x64.dylib 未找到"
fi

if [ -f "$PROJECT_DIR/assets/dll/libgo_decrypt_arm64.dylib" ]; then
    cp "$PROJECT_DIR/assets/dll/libgo_decrypt_arm64.dylib" "$FRAMEWORKS_DIR/"
    echo "  ✅ libgo_decrypt_arm64.dylib"
else
    echo "  ❌ libgo_decrypt_arm64.dylib 未找到"
fi

echo ""
echo "================================"
echo "✅ 后处理完成！"
echo ""
echo "应用位置: $APP_PATH"
ls -lh "$FRAMEWORKS_DIR"/libgo_decrypt*.dylib 2>/dev/null || true
