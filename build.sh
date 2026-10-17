#!/bin/zsh
set -eu
cd "${0:A:h}"
app_path="$PWD/build/EchoGestures.app"
mkdir -p "$app_path/Contents/MacOS"
xcrun clang -std=c11 -Wall -Wextra -Werror -O2 Native/VoiceArrayPrime.c Native/VoiceArrayHelper.c \
  -framework AudioToolbox -framework CoreAudio -framework CoreFoundation \
  -o "$app_path/Contents/MacOS/EchoGesturesVoiceArray"
sources=(Sources/**/*.swift)
xcrun swiftc -Xcc -DACCELERATE_NEW_LAPACK -swift-version 5 -O -target "$(uname -m)-apple-macos14.0" $sources \
  -framework SwiftUI -framework AppKit -framework AVFoundation -framework Accelerate \
  -framework AudioToolbox -framework CoreAudio -framework ApplicationServices \
  -o "$app_path/Contents/MacOS/EchoGestures"
cp Resources/Info.plist "$app_path/Contents/Info.plist"
signing_identity="${ECHOGESTURES_SIGN_IDENTITY:-}"
if [[ -z "$signing_identity" ]]; then
  signing_identity="$(/usr/bin/security find-identity -v -p codesigning | /usr/bin/awk '/"Apple Development:/ {print $2; exit}')"
fi
codesign --force --sign "${signing_identity:--}" --timestamp=none "$app_path/Contents/MacOS/EchoGesturesVoiceArray"
codesign --force --sign "${signing_identity:--}" --timestamp=none "$app_path"
codesign --verify --deep --strict "$app_path"
