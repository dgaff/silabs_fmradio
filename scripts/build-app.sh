#!/bin/zsh
# Build FMRadio.app from the Swift package.
#   scripts/build-app.sh            release build into build/FM Radio.app
#   scripts/build-app.sh debug      debug build
#   SIGN_IDENTITY="Developer ID Application: …" scripts/build-app.sh   sign with a real identity
set -euo pipefail
cd "${0:A:h}/.."

CONFIG=${1:-release}
APP="build/FM Radio.app"
IDENTITY=${SIGN_IDENTITY:--}

swift build -c "$CONFIG" --product FMRadio
BIN=$(swift build -c "$CONFIG" --show-bin-path)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/FMRadio" "$APP/Contents/MacOS/FMRadio"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"

BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" Resources/Info.plist)
if [[ "$IDENTITY" == "-" ]]; then
  # Ad-hoc signatures are identified by code hash, so macOS would re-ask for audio-input
  # permission after every rebuild. An explicit identifier-based requirement keeps it stable.
  REQ=(--requirements "=designated => identifier \"$BUNDLE_ID\"")
else
  REQ=()
fi
codesign --force --sign "$IDENTITY" --options runtime "${REQ[@]}" \
  --entitlements Resources/FMRadio.entitlements "$APP"
codesign --verify --verbose=1 "$APP"
echo "Built $APP"
