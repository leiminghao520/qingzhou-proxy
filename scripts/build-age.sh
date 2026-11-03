#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../tools/agebuild"
# 工具源码和依赖均由 go.mod/go.sum 固定，通过模块校验数据库验证。
export GOSUMDB=sum.golang.org
mkdir -p ../../.build/age-tools
for tool in age age-keygen; do
    go build -mod=readonly -trimpath -o "../../.build/age-tools/$tool" "filippo.io/age/cmd/$tool"
    go version -m "../../.build/age-tools/$tool" > "../../.build/age-tools/$tool.build-info.txt"
done
