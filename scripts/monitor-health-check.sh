#!/bin/bash
# 监控健康检查状态的脚本

QINGZHOU_DIR="$HOME/Library/Application Support/Qingzhou"
LOG_FILE="$QINGZHOU_DIR/diagnostic.log"

echo "=== 汐航健康检查监控 ==="
echo "按 Ctrl+C 停止监控"
echo ""

# 监控最新的日志
tail -f "$LOG_FILE" 2>/dev/null | while read -r line; do
    # 高亮显示关键信息
    if echo "$line" | grep -q "健康检查"; then
        echo "🔍 $line"
    elif echo "$line" | grep -q "dns: lookup failed"; then
        echo "❌ DNS失败: $line"
    elif echo "$line" | grep -q "DNS 超时，不计入失败计数"; then
        echo "✅ DNS超时已跳过: $line"
    elif echo "$line" | grep -q "failedHealthCycles"; then
        echo "⚠️  失败计数: $line"
    elif echo "$line" | grep -q "连通性"; then
        echo "📊 $line"
    fi
done
