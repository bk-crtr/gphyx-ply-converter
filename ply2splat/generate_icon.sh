#!/bin/bash
set -e

SOURCE_IMG="$1"
if [ -z "$SOURCE_IMG" ]; then
    echo "Usage: $0 <source_image>"
    exit 1
fi

ICONSET_DIR="AppIcon.iconset"
mkdir -p "$ICONSET_DIR"

# Center crop to 1:1, resize to 820x820 (20% smaller than 1024), and pad to 1024x1024
sips -s format png -c 768 768 "$SOURCE_IMG" --out temp_crop.png
sips -s format png -z 820 820 temp_crop.png --out temp_resize.png
sips -s format png -p 1024 1024 --padColor 000000 temp_resize.png --out square_source.png

# Generate various sizes from the square source
sips -s format png -z 16 16     square_source.png --out "$ICONSET_DIR/icon_16x16.png"
sips -s format png -z 32 32     square_source.png --out "$ICONSET_DIR/icon_16x16@2x.png"
sips -s format png -z 32 32     square_source.png --out "$ICONSET_DIR/icon_32x32.png"
sips -s format png -z 64 64     square_source.png --out "$ICONSET_DIR/icon_32x32@2x.png"
sips -s format png -z 128 128   square_source.png --out "$ICONSET_DIR/icon_128x128.png"
sips -s format png -z 256 256   square_source.png --out "$ICONSET_DIR/icon_128x128@2x.png"
sips -s format png -z 256 256   square_source.png --out "$ICONSET_DIR/icon_256x256.png"
sips -s format png -z 512 512   square_source.png --out "$ICONSET_DIR/icon_256x256@2x.png"
sips -s format png -z 512 512   square_source.png --out "$ICONSET_DIR/icon_512x512.png"
sips -s format png -z 1024 1024 square_source.png --out "$ICONSET_DIR/icon_512x512@2x.png"

# Create .icns
iconutil -c icns "$ICONSET_DIR"

# Cleanup
rm -rf "$ICONSET_DIR" temp_fit.png square_source.png

echo "✅ AppIcon.icns generated successfully!"
