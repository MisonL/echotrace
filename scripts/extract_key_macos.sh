#!/bin/bash
# macOS 微信数据库密钥自动提取脚本
# 需要禁用 SIP 才能工作
# 用法: ./extract_key.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PID=""
KEY=""

echo "🔑 macOS 微信密钥提取工具"
echo "=========================="
echo ""

# 检查是否需要禁用 SIP
check_sip() {
    local sip_status=$(csrutil status 2>/dev/null || echo "unknown")
    if echo "$sip_status" | grep -q "enabled"; then
        echo "⚠️  警告：系统完整性保护 (SIP) 已启用"
        echo ""
        echo "要提取微信密钥，需要暂时禁用 SIP："
        echo "1. 重启 Mac，按住 Command + R 进入恢复模式"
        echo "2. 在菜单栏选择 实用工具 > 终端"
        echo "3. 运行: csrutil disable"
        echo "4. 重启后再运行此脚本"
        echo ""
        echo "提取完成后，建议重新启用 SIP: csrutil enable"
        echo ""
        return 1
    fi
    echo "✅ SIP 已禁用，可以继续"
    return 0
}

# 查找微信进程
find_wechat_process() {
    local pid=$(pgrep -x WeChat 2>/dev/null || true)
    if [ -z "$pid" ]; then
        echo "❌ 未找到微信进程"
        echo "请先启动微信并登录后再运行此脚本"
        exit 1
    fi
    echo "✅ 找到微信进程: PID=$pid"
    PID="$pid"
}

# 使用 lldb 提取密钥
extract_key_with_lldb() {
    echo ""
    echo "📡 正在通过 lldb 提取密钥..."
    echo "请稍候，这可能需要几秒钟..."
    
    # 创建 lldb 命令脚本
    local lldb_script=$(mktemp)
    cat > "$lldb_script" << 'EOF'
# 设置断点在 sqlite3_key
breakpoint set --name sqlite3_key

# 设置断点命中时的动作
breakpoint command add 1 --one-liner 'script print("KEY:", lldb.frame.registers[0].GetChildAtIndex(1).GetValueAsUnsigned())'

# 继续执行
continue
EOF

    # 运行 lldb（带超时）
    timeout 30 lldb -p "$PID" -s "$lldb_script" 2>&1 | tee /tmp/lldb_output.txt || true
    
    rm -f "$lldb_script"
    
    # 解析输出获取密钥
    if grep -q "KEY:" /tmp/lldb_output.txt; then
        echo "✅ 密钥提取成功！"
    else
        echo "⚠️  未能自动提取密钥"
        echo "可以尝试手动方式，请参考文档"
    fi
}

# 主流程
main() {
    # 检查 SIP 状态
    if ! check_sip; then
        exit 1
    fi
    
    # 查找微信进程
    find_wechat_process
    
    # 提取密钥
    extract_key_with_lldb
    
    echo ""
    echo "=========================="
    echo "如果密钥提取失败，请手动使用以下步骤："
    echo ""
    echo "1. 打开终端，运行: lldb -p $PID"
    echo "2. 在 lldb 中输入: br set -n sqlite3_key"
    echo "3. 输入: br command add 1 -o 'memory read -s1 -c32 \$rsi'"
    echo "4. 输入: c (继续执行)"
    echo "5. 在微信中进行一些操作触发数据库访问"
    echo "6. 查看输出的 32 字节十六进制密钥"
}

main "$@"
