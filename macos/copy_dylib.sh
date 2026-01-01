#!/bin/bash
# 自动复制 Go 解密库到应用包
# 此脚本被 Xcode Build Phase 调用

set -e

# 获取构建产品目录
if [ -z "$BUILT_PRODUCTS_DIR" ]; then
    echo "警告：BUILT_PRODUCTS_DIR 未设置，跳过 dylib 复制"
    exit 0
fi

FRAMEWORKS_DIR="$BUILT_PRODUCTS_DIR/$PRODUCT_NAME.app/Contents/Frameworks"
PROJECT_DIR="${SRCROOT}/.."

echo "📂 复制 Go 解密库到 $FRAMEWORKS_DIR"

# 确保目录存在
mkdir -p "$FRAMEWORKS_DIR"

# 复制 dylib 文件
if [ -f "$PROJECT_DIR/assets/dll/libgo_decrypt_x64.dylib" ]; then
    cp "$PROJECT_DIR/assets/dll/libgo_decrypt_x64.dylib" "$FRAMEWORKS_DIR/"
    echo "  ✅ libgo_decrypt_x64.dylib"
fi

if [ -f "$PROJECT_DIR/assets/dll/libgo_decrypt_arm64.dylib" ]; then
    cp "$PROJECT_DIR/assets/dll/libgo_decrypt_arm64.dylib" "$FRAMEWORKS_DIR/"
    echo "  ✅ libgo_decrypt_arm64.dylib"
fi

# 签名 dylib
for dylib in "$FRAMEWORKS_DIR"/libgo_decrypt*.dylib; do
    if [ -f "$dylib" ]; then
        codesign --force --sign - "$dylib" 2>/dev/null || true
    fi
done

echo "✅ dylib 复制完成"
