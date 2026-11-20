#!/bin/bash
# 测试降级修复的验证脚本

set -e

echo "=== 汐航降级问题修复验证脚本 ==="
echo ""

# 1. 检查修复是否已应用
echo "1. 检查代码修复..."
if grep -q "DNS 超时不累计为控制接口失败" Sources/Qingzhou/AppModel.swift; then
    echo "✅ DNS 超时特殊处理已添加"
else
    echo "❌ DNS 超时修复未应用"
    exit 1
fi

# 2. 备份当前连接恢复状态
echo ""
echo "2. 备份连接恢复状态..."
QINGZHOU_DIR="$HOME/Library/Application Support/Qingzhou"
RECOVERY_FILE="$QINGZHOU_DIR/connection-recovery.json"
BACKUP_FILE="$QINGZHOU_DIR/connection-recovery.backup-test-$(date +%Y%m%d-%H%M%S).json"

if [ -f "$RECOVERY_FILE" ]; then
    cp "$RECOVERY_FILE" "$BACKUP_FILE"
    echo "✅ 已备份到: $BACKUP_FILE"
else
    echo "⚠️  未找到恢复状态文件(正常情况)"
fi

# 3. 检查当前失败节点
echo ""
echo "3. 检查当前失败节点..."
if [ -f "$RECOVERY_FILE" ]; then
    FAILED_COUNT=$(jq 'to_entries | map(select(.value.verified == false)) | length' "$RECOVERY_FILE" 2>/dev/null || echo "0")
    echo "未验证节点数: $FAILED_COUNT"
    
    if [ "$FAILED_COUNT" -gt 0 ]; then
        echo "⚠️  检测到失败节点,建议清除"
    else
        echo "✅ 无失败节点"
    fi
else
    echo "✅ 恢复状态文件不存在(理想状态)"
fi

# 4. 检查 DNS 配置
echo ""
echo "4. 检查 DNS 配置..."
DNS_COUNT=$(scutil --dns 2>/dev/null | grep "nameserver\[0\]" | wc -l | tr -d ' ')
echo "配置的 DNS 解析器数量: $DNS_COUNT"

# 5. 检查诊断日志中的 DNS 错误
echo ""
echo "5. 统计最近的 DNS 超时..."
if [ -f "$QINGZHOU_DIR/diagnostic.log" ]; then
    DNS_TIMEOUT_COUNT=$(grep -c "dns: lookup failed\|context deadline exceeded" "$QINGZHOU_DIR/diagnostic.log" 2>/dev/null || echo "0")
    echo "诊断日志中的 DNS 超时次数: $DNS_TIMEOUT_COUNT"
fi

# 6. 生成修复建议
echo ""
echo "=== 修复建议 ==="
echo ""
echo "立即执行:"
echo "  1. 完全退出汐航应用(⌘Q)"
echo "  2. 运行清除脚本: bash ~/Desktop/reset-connection-recovery.sh"
echo "  3. 重新启动应用"
echo "  4. 手动测速所有节点"
echo ""
echo "长期优化:"
echo "  1. 重新编译应用使 DNS 超时修复生效"
echo "  2. 考虑添加公共 DNS 后备"
echo "  3. 监控 DNS 解析性能"
echo ""

echo "=== 验证完成 ==="
