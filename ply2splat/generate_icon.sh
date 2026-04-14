#!/bin/bash
set -e

SOURCE_IMG="$1"
if [ -z "$SOURCE_IMG" ]; then
    echo "Usage: $0 <source_image>"
    exit 1
fi

ICONSET_DIR="AppIcon.iconset"
mkdir -p "$ICONSET_DIR"

# Generate various sizes
sips -s format png -z 16 16     "$SOURCE_IMG" --out "$ICONSET_DIR/icon_16x16.png"
sips -s format png -z 32 32     "$SOURCE_IMG" --out "$ICONSET_DIR/icon_16x16@2x.png"
sips -s format png -z 32 32     "$SOURCE_IMG" --out "$ICONSET_DIR/icon_32x32.png"
sips -s format png -z 64 64     "$SOURCE_IMG" --out "$ICONSET_DIR/icon_32x32@2x.png"
sips -s format png -z 128 128   "$SOURCE_IMG" --out "$ICONSET_DIR/icon_128x128.png"
sips -s format png -z 256 256   "$SOURCE_IMG" --out "$ICONSET_DIR/icon_128x128@2x.png"
sips -s format png -z 256 256   "$SOURCE_IMG" --out "$ICONSET_DIR/icon_256x256.png"
sips -s format png -z 512 512   "$SOURCE_IMG" --out "$ICONSET_DIR/icon_256x256@2x.png"
sips -s format png -z 512 512   "$SOURCE_IMG" --out "$ICONSET_DIR/icon_512x512.png"
sips -s format png -z 1024 1024 "$SOURCE_IMG" --out "$ICONSET_DIR/icon_512x512@2x.png"

# Create .icns
iconutil -c icns "$ICONSET_DIR"

# Cleanup
rm -rf "$ICONSET_DIR"

echo "✅ AppIcon.icns generated successfully!"
