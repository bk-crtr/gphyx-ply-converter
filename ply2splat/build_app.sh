#!/bin/bash
set -e

# Kill any previous versions that might be running
killall ply2splat 2>/dev/null || true
killall GPHYX_SplatUtility 2>/dev/null || true
killall GPHYX_PLYUtility 2>/dev/null || true
killall "PLY Utility" 2>/dev/null || true

APP_NAME="GPHYX_PLYUtility"
APP_DIR="$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

echo "Building executable (Release mode)..."
swift build -c release

echo "Creating App Bundle Structure..."
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"

echo "Copying Executable..."
cp .build/release/ply2splat "$MACOS_DIR/"

# Copying Resources
cp Sources/ply2splat/background.png "$RESOURCES_DIR/"
cp Sources/ply2splat/GPHYX_LOGO.png "$RESOURCES_DIR/"
cp Sources/ply2splat/G_ply2splat.jpeg "$RESOURCES_DIR/"
cp AppIcon.icns "$RESOURCES_DIR/"

# Copying Fonts
mkdir -p "$RESOURCES_DIR/Fonts"
cp "/Library/Fonts/Cairo-VariableFont_slnt,wght.ttf" "$RESOURCES_DIR/Fonts/"

echo "Creating Info.plist..."
cat > "$CONTENTS_DIR/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>ply2splat</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.gphyx.plyutility</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>GPHYX PLY Utility</string>
    <key>ATSApplicationFontsPath</key>
    <string>Fonts</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

echo "Signing the Application..."
xattr -cr "$APP_DIR"
codesign --force --deep --sign "Developer ID Application: GADZHI MUSALCHIEV (NM74G59H9M)" "$APP_DIR"

echo "✅ Done! Application created at $APP_DIR and signed!"
echo "You can launch it by running: open $APP_DIR"
