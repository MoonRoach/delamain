#!/bin/sh
# Build hub-viz (the server, viz.html embedded) and DelamainLive.saver (native, no WebKit) into ./build.
set -eu
cd "$(dirname "$0")"
saver=build/DelamainLive.saver
rm -rf "$saver"
mkdir -p "$saver/Contents/MacOS" "$saver/Contents/Resources"
go build -o build/hub-viz .
cp saver/Info.plist "$saver/Contents/Info.plist"
cp assets/*.png assets/*.jpg "$saver/Contents/Resources/"
# a screen saver must be a loadable bundle (MH_BUNDLE): System Settings skips a dylib without a word
swiftc -O -swift-version 5 -parse-as-library -emit-executable -Xlinker -bundle -module-name DelamainLive \
  -target "$(uname -m)-apple-macos13" \
  -framework ScreenSaver -framework QuartzCore -framework AppKit -framework CoreImage -framework IOKit \
  saver/*.swift -o "$saver/Contents/MacOS/DelamainLive"
codesign -s - --force "$saver"
echo "built: build/hub-viz $saver"
