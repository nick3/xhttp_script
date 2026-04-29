#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)

if ! command -v bats >/dev/null 2>&1; then
    echo "[ERROR] bats 未安装。请先安装 bats-core 后再运行测试。" >&2
    echo "        macOS: brew install bats-core" >&2
    echo "        Debian/Ubuntu: apt-get install bats" >&2
    exit 127
fi

bash -n "$REPO_ROOT/download.sh"
bash -n "$REPO_ROOT/install.sh"
bats "$SCRIPT_DIR"/*.bats
