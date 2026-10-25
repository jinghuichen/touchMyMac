#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/TouchMyMac.xcodeproj"
SCHEME="TouchMyMac"
CONFIGURATION="${CONFIGURATION:-Debug}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-/tmp/TouchMyMacDerivedData}"
APP_NAME="TouchMyMac"

usage() {
  cat <<EOF
Usage:
  $(basename "$0") [--app-dir /Applications] [--configuration Debug|Release]

Env vars:
  DERIVED_DATA_PATH=...  (default: $DERIVED_DATA_PATH)
  CONFIGURATION=...      (default: $CONFIGURATION)
EOF
}

APP_DIR=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --app-dir)
      APP_DIR="${2:-}"
      shift 2
      ;;
    --configuration)
      CONFIGURATION="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown arg: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$APP_DIR" ]]; then
  APP_DIR="/Applications"
fi

TARGET_APP_PATH="$APP_DIR/$APP_NAME.app"

NEED_SUDO=0
if [[ ! -w "$APP_DIR" ]]; then
  echo "==> Note: $APP_DIR is not writable; will use sudo for install/remove." >&2
  NEED_SUDO=1
fi

run_install_cmd() {
  if [[ "$NEED_SUDO" -eq 1 ]]; then
    sudo "$@"
  else
    "$@"
  fi
}

# Build first: if it fails, `set -e` stops here and the installed app stays untouched.
echo "==> Building ($CONFIGURATION)…"
rm -rf "$DERIVED_DATA_PATH"

xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -sdk macosx \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  build

BUILT_APP_PATH="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/$APP_NAME.app"
if [[ ! -d "$BUILT_APP_PATH" ]]; then
  echo "Build succeeded but app not found at: $BUILT_APP_PATH" >&2
  exit 1
fi

echo "==> Quitting running app (if any)…"
osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1 || true
pkill -x "$APP_NAME" >/dev/null 2>&1 || true

echo "==> Removing existing install: $TARGET_APP_PATH"
if [[ -e "$TARGET_APP_PATH" ]]; then
  run_install_cmd rm -rf "$TARGET_APP_PATH"
fi

echo "==> Installing to: $TARGET_APP_PATH"
run_install_cmd mkdir -p "$APP_DIR"
run_install_cmd ditto "$BUILT_APP_PATH" "$TARGET_APP_PATH"

echo "==> Launching…"
open "$TARGET_APP_PATH"

echo "==> Done."
