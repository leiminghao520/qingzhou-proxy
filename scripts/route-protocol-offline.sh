#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/route-protocol-offline
clang -std=c11 -Wall -Wextra -Werror -fsanitize=address,undefined -g \
    -I Sources/CQingzhouRoute/include scripts/route-codec-export.c \
    Sources/CQingzhouRoute/QingzhouRoute.c Sources/CQingzhouRoute/RouteRequestValidation.c \
    -o .build/route-protocol-offline/export
.build/route-protocol-offline/export > .build/route-protocol-offline/corpus.jsonl
/usr/bin/python3 scripts/route-protocol-oracle.py .build/route-protocol-offline/corpus.jsonl
