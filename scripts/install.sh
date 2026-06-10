#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="CursorBar"
INSTALLED_APP="/Applications/$APP_NAME.app"

if ! command -v swift >/dev/null 2>&1; then
    echo "Swift is not installed." >&2
    echo "Install Xcode or Apple Command Line Tools:" >&2
    echo "  xcode-select --install" >&2
    exit 1
fi

if ! swift --version | grep -q "Apple Swift"; then
    echo "Could not find Apple Swift toolchain." >&2
    exit 1
fi

DB="$HOME/Library/Application Support/Cursor/User/globalStorage/state.vscdb"
if [[ ! -f "$DB" ]]; then
    echo "Warning: Cursor does not appear to be installed or logged in." >&2
    echo "Expected database at:" >&2
    echo "  $DB" >&2
    echo "Install Cursor and sign in, then run this script again." >&2
    exit 1
fi

echo "Building and installing $APP_NAME..."
bash "$ROOT/scripts/package.sh" --install

echo "Launching $APP_NAME..."
bash "$ROOT/scripts/launch.sh"

echo
echo "Done. Look for your usage percentage in the menu bar (e.g. 42%)."
echo "Installed to: $INSTALLED_APP"
