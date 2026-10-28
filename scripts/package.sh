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
cp Resources/Clipper.sdef "$APP/Contents/Resources/Clipper.sdef"
# The app icon is drawn in code (ClipperMark) so it always matches the menu bar glyph.
ICONSET=$(mktemp -d)/Clipper.iconset
.build/release/Clipper --make-icon "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Clipper.icns"
BUILD=$(git rev-parse --short HEAD)
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>Clipper</string>
  <key>CFBundleIdentifier</key><string>com.royelia.clipper</string>
  <key>CFBundleName</key><string>Clipper</string>
  <key>CFBundleIconFile</key><string>Clipper</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.3.0</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>CFBundleURLTypes</key><array><dict>
    <key>CFBundleURLName</key><string>com.royelia.clipper</string>
    <key>CFBundleURLSchemes</key><array><string>clipper</string></array>
  </dict></array>
  <key>NSAppleScriptEnabled</key><true/>
  <key>OSAScriptingDefinition</key><string>Clipper.sdef</string>
  <key>NSUserActivityTypes</key><array><string>com.royelia.clipper.activity</string></array>
  <key>UTExportedTypeDeclarations</key><array><dict>
    <key>UTTypeIdentifier</key><string>com.royelia.clipper.clip-id</string>
    <key>UTTypeDescription</key><string>Clipper clip</string>
    <key>UTTypeConformsTo</key><array><string>public.data</string></array>
  </dict></array>
  <key>NSHumanReadableCopyright</key><string>Personal build</string>
</dict></plist>
PLIST
# A stable identity keeps the Accessibility grant across rebuilds; ad-hoc signing changes it every build.
IDENTITY="Clipper Local Signing"
security find-identity -p codesigning | grep -q "$IDENTITY" || { echo "no '$IDENTITY' identity; signing ad-hoc (Accessibility must be re-allowed after each build)"; IDENTITY=-; }
codesign --force --deep --sign "$IDENTITY" "$APP" 2>&1 | tail -1
codesign --verify --deep --strict "$APP" && echo "packaged $APP build $BUILD"
