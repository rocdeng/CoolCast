#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
JDK_HOME="/opt/homebrew/Cellar/openjdk@17/17.0.19/libexec/openjdk.jdk/Contents/Home"
ANDROID_SDK="/Users/dengpeng/Library/Android/sdk"
FLUTTER_BIN="/Users/dengpeng/Documents/flutter/bin/flutter"

if [ ! -x "$JDK_HOME/bin/java" ]; then
  echo "JDK 17 not found: $JDK_HOME" >&2
  exit 1
fi

if [ ! -f "$ANDROID_SDK/platforms/android-36/android.jar" ]; then
  echo "Android SDK platform 36 not found: $ANDROID_SDK/platforms/android-36/android.jar" >&2
  echo "Install it with sdkmanager before building." >&2
  exit 1
fi

if [ ! -x "$FLUTTER_BIN" ]; then
  echo "Flutter not found: $FLUTTER_BIN" >&2
  exit 1
fi

cd "$ROOT_DIR"
export JAVA_HOME="$JDK_HOME"
export ANDROID_HOME="$ANDROID_SDK"
export ANDROID_SDK_ROOT="$ANDROID_SDK"
export GRADLE_USER_HOME="${GRADLE_USER_HOME:-/private/tmp/coolcast-gradle}"

"$FLUTTER_BIN" build apk --debug
