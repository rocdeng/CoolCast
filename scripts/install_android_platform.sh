#!/usr/bin/env bash
set -euo pipefail

JDK_HOME="/opt/homebrew/Cellar/openjdk@17/17.0.19/libexec/openjdk.jdk/Contents/Home"
ANDROID_SDK="/opt/homebrew/share/android-commandlinetools"
SDKMANAGER="/opt/homebrew/bin/sdkmanager"

if [ ! -x "$JDK_HOME/bin/java" ]; then
  echo "JDK 17 not found: $JDK_HOME" >&2
  exit 1
fi

if [ ! -x "$SDKMANAGER" ]; then
  echo "sdkmanager not found: $SDKMANAGER" >&2
  exit 1
fi

export JAVA_HOME="$JDK_HOME"

yes | "$SDKMANAGER" --sdk_root="$ANDROID_SDK" \
  "platform-tools" \
  "platforms;android-36" \
  "build-tools;34.0.0"
