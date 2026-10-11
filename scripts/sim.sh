#!/bin/zsh
# Build, install and launch DanmuTV on the tvOS simulator, optionally with a deep link, then screenshot.
#   scripts/sim.sh [danmutv://video/BV…] [screenshot.png] [wait-seconds]
# Extra launch arguments can be passed via SIM_ARGS, e.g. SIM_ARGS="-startAt 1325".
set -e
cd "$(dirname "$0")/.."
SIM=${SIM:-$(xcrun simctl list devices available | grep -m1 "Apple TV 4K (3rd generation) (" | grep -oE '[0-9A-F-]{36}')}
xcrun simctl boot "$SIM" 2>/dev/null || true
xcodebuild -project DanmuTV.xcodeproj -scheme DanmuTV -destination "platform=tvOS Simulator,id=$SIM" \
  -derivedDataPath build/DerivedData build -quiet
APP=build/DerivedData/Build/Products/Debug-appletvsimulator/DanmuTV.app
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Info.plist")
xcrun simctl install "$SIM" "$APP"
# Terminating and relaunching in one step sometimes leaves the app behind the home screen.
xcrun simctl terminate "$SIM" "$BUNDLE_ID" 2>/dev/null || true
sleep 2
if [[ -n "$1" ]]; then
  xcrun simctl launch "$SIM" "$BUNDLE_ID" -muted YES ${=SIM_ARGS} -deeplink "$1" >/dev/null
else
  xcrun simctl launch "$SIM" "$BUNDLE_ID" -muted YES >/dev/null
fi
sleep "${3:-8}"
[[ -n "$2" ]] && xcrun simctl io "$SIM" screenshot "$2" >/dev/null 2>&1
echo "launched on $SIM (muted). Stop with: xcrun simctl terminate $SIM "$BUNDLE_ID""
