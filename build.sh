#!/bin/bash
# Compila el servidor MCP en modo release. Uso: ./build.sh
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
echo "Binario: $(pwd)/.build/release/computer-use-mcp"
