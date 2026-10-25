#!/bin/zsh
# Builds a release Clipper.app in dist/ (ad-hoc signed) with the stdio bridge inside.
set -e
cd "$(dirname "$0")/.."
swift build -c release 2>&1 | tail -2
APP=dist/Clipper.app
rm -rf "${APP:?}"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Clipper "$APP/Contents/MacOS/Clipper"
cp .build/release/clipper-mcp-stdio "$APP/Contents/MacOS/clipper-mcp-stdio"
BUILD=$(git rev-parse --short HEAD)
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>Clipper</string>
  <key>CFBundleIdentifier</key><string>com.royelia.clipper</string>
  <key>CFBundleName</key><string>Clipper</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>Personal build</string>
</dict></plist>
PLIST
# A stable identity keeps the Accessibility grant across rebuilds; ad-hoc signing changes it every build.
IDENTITY="Clipper Local Signing"
security find-identity -p codesigning | grep -q "$IDENTITY" || { echo "no '$IDENTITY' identity; signing ad-hoc (Accessibility must be re-allowed after each build)"; IDENTITY=-; }
codesign --force --deep --sign "$IDENTITY" "$APP" 2>&1 | tail -1
codesign --verify --deep --strict "$APP" && echo "packaged $APP build $BUILD"
