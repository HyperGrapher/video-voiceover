#!/usr/bin/env bash
# generate_iconset_from_png.sh - Generate macOS app icons from a PNG and place
# them in a SwiftPM-friendly Resources folder.
#
# Usage (run from the project root):
#   bash Scripts/generate_iconset_from_png.sh [source.png] [path/to/Assets.xcassets] [app-name]
#
# Defaults:
#   source PNG   -> Icon.png
#   xcassets dir -> Sources/<app-name>/Resources/Assets.xcassets
#   app name     -> parent folder name

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

SOURCE_PNG="${1:-Icon.png}"
XCASSETS="${2:-}"
APP_NAME="${APP_NAME:-${3:-$(basename "$ROOT")}}"
RESOURCES_DIR="Sources/$APP_NAME/Resources"

if [[ -z "$XCASSETS" ]]; then
  XCASSETS="$RESOURCES_DIR/Assets.xcassets"
fi

APPICONSET="$XCASSETS/AppIcon.appiconset"

echo "==> generate_iconset_from_png.sh settings"
echo "    root          : $ROOT"
echo "    app name      : $APP_NAME"
echo "    source PNG    : $SOURCE_PNG"
echo "    resources dir : $RESOURCES_DIR"
echo "    asset catalog : $XCASSETS"
echo "    app icon set  : $APPICONSET"

if [[ ! -f "$SOURCE_PNG" ]]; then
  echo "ERROR: Source PNG not found: $SOURCE_PNG" >&2
  exit 1
fi

mkdir -p "$APPICONSET" "$RESOURCES_DIR"

# Each row: <logical-size> <scale>; actual pixel size = logical * scale.
# macOS requires all of these for a universal app icon.
declare -a SIZES=(
  "16  1"
  "16  2"
  "32  1"
  "32  2"
  "128 1"
  "128 2"
  "256 1"
  "256 2"
  "512 1"
  "512 2"
)

generate_icon() {
  local logical=$1
  local scale=$2
  local pixels=$(( logical * scale ))
  local scale_label
  [[ "$scale" -eq 1 ]] && scale_label="1x" || scale_label="2x"
  local filename="icon_${logical}x${logical}@${scale_label}.png"

  sips -z "$pixels" "$pixels" "$SOURCE_PNG" \
       --out "$APPICONSET/$filename" \
       >/dev/null 2>&1

  echo "  generated ${pixels}x${pixels}px -> $filename"
}

echo ""
echo "==> Generating icons"
for entry in "${SIZES[@]}"; do
  read -r logical scale <<< "$entry"
  generate_icon "$logical" "$scale"
done

# Xcode reads this file to map sizes/scales to filenames.
cat > "$APPICONSET/Contents.json" << 'EOF'
{
  "images" : [
    { "filename" : "icon_16x16@1x.png",  "idiom" : "mac", "scale" : "1x", "size" : "16x16"  },
    { "filename" : "icon_16x16@2x.png",  "idiom" : "mac", "scale" : "2x", "size" : "16x16"  },
    { "filename" : "icon_32x32@1x.png",  "idiom" : "mac", "scale" : "1x", "size" : "32x32"  },
    { "filename" : "icon_32x32@2x.png",  "idiom" : "mac", "scale" : "2x", "size" : "32x32"  },
    { "filename" : "icon_128x128@1x.png","idiom" : "mac", "scale" : "1x", "size" : "128x128"},
    { "filename" : "icon_128x128@2x.png","idiom" : "mac", "scale" : "2x", "size" : "128x128"},
    { "filename" : "icon_256x256@1x.png","idiom" : "mac", "scale" : "1x", "size" : "256x256"},
    { "filename" : "icon_256x256@2x.png","idiom" : "mac", "scale" : "2x", "size" : "256x256"},
    { "filename" : "icon_512x512@1x.png","idiom" : "mac", "scale" : "1x", "size" : "512x512"},
    { "filename" : "icon_512x512@2x.png","idiom" : "mac", "scale" : "2x", "size" : "512x512"}
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
EOF

echo ""
echo "Contents.json written."

ICONSET_TMP="$(mktemp -d)/AppIcon.iconset"
trap 'rm -rf "$(dirname "$ICONSET_TMP")"' EXIT
mkdir -p "$ICONSET_TMP"

# iconutil expects a specific naming convention without the @1x suffix.
while read -r src_name dest_name; do
  cp "$APPICONSET/$src_name" "$ICONSET_TMP/$dest_name"
done <<EOF
icon_16x16@1x.png icon_16x16.png
icon_16x16@2x.png icon_16x16@2x.png
icon_32x32@1x.png icon_32x32.png
icon_32x32@2x.png icon_32x32@2x.png
icon_128x128@1x.png icon_128x128.png
icon_128x128@2x.png icon_128x128@2x.png
icon_256x256@1x.png icon_256x256.png
icon_256x256@2x.png icon_256x256@2x.png
icon_512x512@1x.png icon_512x512.png
icon_512x512@2x.png icon_512x512@2x.png
EOF

ICNS_OUT="$RESOURCES_DIR/Icon.icns"
iconutil -c icns "$ICONSET_TMP" -o "$ICNS_OUT"
cp "$ICNS_OUT" "$ROOT/Icon.icns"

echo ""
echo "Done."
echo "    Asset catalog : $APPICONSET"
echo "    AppIcon.icns  : $ICNS_OUT"
echo "    Root Icon.icns: $ROOT/Icon.icns"
echo ""
echo "Add resources to the executable target in Package.swift if they are not already present:"
echo ""
cat <<EOF
    .executableTarget(
        name: "$APP_NAME",
        resources: [
            .process("Resources")
        ]
    )
EOF
echo ""
echo "Then package the release app with icons:"
echo "  Scripts/package_app.sh release"
echo ""
echo "Packaged app will be created at:"
echo "  $ROOT/$APP_NAME.app"
