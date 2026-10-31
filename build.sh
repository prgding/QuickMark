#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h}"
APP="$ROOT/QuickMark.app"
BUILD_CACHE="${TMPDIR:-/tmp}/quickmark-swift-cache"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$BUILD_CACHE"
xcrun swiftc -O -swift-version 5 -target arm64-apple-macosx14.0 \
  -module-cache-path "$BUILD_CACHE" \
  -framework AppKit -framework SwiftUI -framework ScreenCaptureKit -framework Carbon -framework QuartzCore \
  "$ROOT/Source/Drawing.swift" "$ROOT/Source/RectangleEditing.swift" "$ROOT/Source/HighRefresh.swift" "$ROOT/Source/Overlay.swift" \
  "$ROOT/Source/PinnedCapture.swift" "$ROOT/Source/ScreenCaptureService.swift" "$ROOT/Source/PNGExport.swift" "$ROOT/Source/GestureDiagnostics.swift" "$ROOT/Source/App.swift" "$ROOT/Source/SelfTest.swift" "$ROOT/Source/PerformanceTest.swift" "$ROOT/Source/main.swift" \
  -o "$APP/Contents/MacOS/QuickMark"
cp "$ROOT/Source/Info.plist" "$APP/Contents/Info.plist"
xcrun swift -module-cache-path "$BUILD_CACHE" "$ROOT/Source/MakeIcon.swift" "$BUILD_CACHE/QuickMark.iconset"
iconutil -c icns "$BUILD_CACHE/QuickMark.iconset" -o "$APP/Contents/Resources/QuickMark.icns"
RELEASED_AT="$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')"
/usr/bin/plutil -insert QuickMarkReleaseDate -date "$RELEASED_AT" "$APP/Contents/Info.plist"
codesign --force --sign - --identifier local.dingshuai.QuickMark "$APP"
print "Built: $APP"
