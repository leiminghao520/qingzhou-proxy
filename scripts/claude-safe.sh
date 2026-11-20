#!/bin/bash
set -euo pipefail
# 此入口为 Claude Code 及其普通子进程加上出站限制；第三方常驻服务仍需独立规则。
proxy=http://127.0.0.1:17891
if ! /usr/bin/nc -z -G 2 127.0.0.1 17891; then
    echo 'Claude 专用代理未运行，请在汐航中启动；拒绝启动 Claude Code。' >&2
    exit 1
fi
claude_binary="$(command -v claude || true)"
if [ -z "$claude_binary" ]; then echo '未找到 Claude Code。' >&2; exit 1; fi
# 限制整个新进程及继承子进程，避免不遵守代理变量的普通工具直接访问公网。
profile='(version 1) (allow default) (deny network-outbound) (allow network-outbound (remote tcp "localhost:17891"))'
exec /usr/bin/sandbox-exec -p "$profile" /usr/bin/env \
    HTTP_PROXY="$proxy" HTTPS_PROXY="$proxy" http_proxy="$proxy" https_proxy="$proxy" \
    ALL_PROXY="$proxy" all_proxy="$proxy" NO_PROXY= no_proxy= \
    "$claude_binary" "$@"
