#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/route-transport-offline
clang -std=c11 -Wall -Wextra -Werror -fsanitize=address,undefined -g \
    -I Sources/CQingzhouRoute/include scripts/route-transport-offline.c \
    Sources/CQingzhouRoute/RouteRequestValidation.c Sources/CQingzhouRoute/RouteTransport.c \
    -o .build/route-transport-offline/checks
.build/route-transport-offline/checks
