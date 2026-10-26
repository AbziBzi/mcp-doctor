#!/bin/zsh
# Builds the app, copies it to ~/Applications and (re)starts it.
set -euo pipefail
cd "${0:A:h}/.."

scripts/build-app.sh
pkill -x MCPDoctor 2>/dev/null || true
mkdir -p ~/Applications
rm -rf ~/Applications/"MCP Doctor.app"
cp -R "build/MCP Doctor.app" ~/Applications/
open ~/Applications/"MCP Doctor.app"
echo "Installed to ~/Applications/MCP Doctor.app"
