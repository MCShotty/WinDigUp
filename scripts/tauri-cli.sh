#!/bin/bash
# Invoke the pinned CLI directly. Windows cmd.exe can lose npm's temporary bin directory on long PATHs.
# No PATH shim or global npm installation is required, including when npm bin-links is disabled.
set -euo pipefail
TAURI_CLI=2.12.2
tauri_cli_dir=$(mktemp -d)
trap 'rm -rf "$tauri_cli_dir"' EXIT
npm install --prefix "$tauri_cli_dir" --no-save --no-package-lock --no-audit --no-fund \
  --ignore-scripts --include=optional --bin-links=false "@tauri-apps/cli@$TAURI_CLI"
tauri_js="$tauri_cli_dir/node_modules/@tauri-apps/cli/tauri.js"
node "$tauri_js" "$@"
