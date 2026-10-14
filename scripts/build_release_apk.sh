#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

KEY_PROPERTIES="$ROOT_DIR/android/key.properties"
if [ ! -f "$KEY_PROPERTIES" ]; then
  echo "Release signing config not found: $KEY_PROPERTIES" >&2
  echo "Expected keys: storeFile, storePassword, keyAlias, keyPassword." >&2
  exit 1
fi

STORE_FILE="$(sed -n 's/^storeFile=//p' "$KEY_PROPERTIES")"
if [ ! -f "$STORE_FILE" ]; then
  echo "Release keystore not found: $STORE_FILE" >&2
  exit 1
fi

"$FLUTTER_BIN" build apk --release

APK="$ROOT_DIR/build/app/outputs/flutter-apk/app-release.apk"
APKSIGNER="$(ls -d "$ANDROID_SDK"/build-tools/*/apksigner 2>/dev/null | sort -V | tail -n 1 || true)"
if [ -n "$APKSIGNER" ]; then
  "$APKSIGNER" verify --print-certs "$APK" | grep -E "Signer.*certificate (DN|SHA-256)"
else
  echo "apksigner not found under $ANDROID_SDK/build-tools; skipped signature check." >&2
fi
