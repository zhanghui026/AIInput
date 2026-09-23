#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="AIInput"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="$ROOT_DIR/$APP_NAME.app"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true
"$ROOT_DIR/build.sh"

open_app() {
    /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
    run)
        open_app
        ;;
    --verify|verify)
        open_app
        sleep 1
        pgrep -x "$APP_NAME" >/dev/null
        ;;
    *)
        echo "usage: $0 [run|--verify]" >&2
        exit 2
        ;;
esac
