#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

default_app_name() {
  basename "$ROOT"
}

CONF=release
APP_NAME=${APP_NAME:-}
while [[ $# -gt 0 ]]; do
  case "$1" in
    debug|release)
      CONF="$1"
      shift
      ;;
    --app-name)
      APP_NAME="${2:?Missing value for --app-name}"
      shift 2
      ;;
    --app-name=*)
      APP_NAME="${1#*=}"
      shift
      ;;
    --help|-h)
      echo "Usage: $(basename "$0") [debug|release] [APP_NAME] [--app-name APP_NAME]"
      exit 0
      ;;
    *)
      if [[ -z "$APP_NAME" ]]; then
        APP_NAME="$1"
        shift
      else
        echo "ERROR: Unknown argument: $1" >&2
        exit 1
      fi
      ;;
  esac
done

APP_NAME=${APP_NAME:-$(default_app_name)}
BUNDLE_ID=${BUNDLE_ID:-com.local.${APP_NAME}}
MACOS_MIN_VERSION=${MACOS_MIN_VERSION:-15.0}
MENU_BAR_APP=${MENU_BAR_APP:-0}
SIGNING_MODE=${SIGNING_MODE:-}
APP_IDENTITY=${APP_IDENTITY:-}
SPARKLE_FEED_URL=${SPARKLE_FEED_URL:-}
SPARKLE_PUBLIC_KEY=${SPARKLE_PUBLIC_KEY:-}

if [[ -f "$ROOT/version.env" ]]; then
  source "$ROOT/version.env"
else
  MARKETING_VERSION=${MARKETING_VERSION:-0.1.0}
  BUILD_NUMBER=${BUILD_NUMBER:-1}
fi

ARCH_LIST=( ${ARCHES:-} )
if [[ ${#ARCH_LIST[@]} -eq 0 ]]; then
  ARCH_LIST=(arm64 x86_64)
fi

echo "==> package_app.sh settings"
echo "    root              : $ROOT"
echo "    app name          : $APP_NAME"
echo "    bundle id         : $BUNDLE_ID"
echo "    configuration     : $CONF"
echo "    architectures     : ${ARCH_LIST[*]}"
echo "    macOS minimum     : $MACOS_MIN_VERSION"
echo "    signing mode      : ${SIGNING_MODE:-adhoc}"
echo "    signing identity  : ${APP_IDENTITY:-none}"
echo "    menu bar app      : $MENU_BAR_APP"

for ARCH in "${ARCH_LIST[@]}"; do
  swift build -c "$CONF" --arch "$ARCH"
done

APP="$ROOT/${APP_NAME}.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

# Convert Icon.icon to Icon.icns if present (requires iconutil).
ICON_SOURCE="$ROOT/Icon.icon"
ICON_TARGET="$ROOT/Icon.icns"
if [[ -f "$ICON_SOURCE" ]]; then
  iconutil --convert icns --output "$ICON_TARGET" "$ICON_SOURCE"
fi

LSUI_VALUE="false"
if [[ "$MENU_BAR_APP" == "1" ]]; then
  LSUI_VALUE="true"
fi

BUILD_TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
GIT_COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")

SPARKLE_PLIST_KEYS=""
if [[ -n "$SPARKLE_PUBLIC_KEY" ]]; then
  if [[ -z "$SPARKLE_FEED_URL" ]]; then
    SPARKLE_FEED_URL="https://example.com/appcast.xml"
  fi
  SPARKLE_PLIST_KEYS="    <key>SUFeedURL</key><string>${SPARKLE_FEED_URL}</string>
    <key>SUPublicEDKey</key><string>${SPARKLE_PUBLIC_KEY}</string>"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key><string>${APP_NAME}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${MARKETING_VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key><string>${MACOS_MIN_VERSION}</string>
    <key>LSUIElement</key><${LSUI_VALUE}/>
    <key>CFBundleIconFile</key><string>Icon</string>
    <key>BuildTimestamp</key><string>${BUILD_TIMESTAMP}</string>
    <key>GitCommit</key><string>${GIT_COMMIT}</string>
${SPARKLE_PLIST_KEYS}
</dict>
</plist>
PLIST

build_product_path() {
  local name="$1"
  local arch="$2"
  case "$arch" in
    arm64|x86_64) echo ".build/${arch}-apple-macosx/$CONF/$name" ;;
    *) echo ".build/$CONF/$name" ;;
  esac
}

verify_binary_arches() {
  local binary="$1"; shift
  local expected=("$@")
  local actual
  actual=$(lipo -archs "$binary")
  local actual_count expected_count
  actual_count=$(wc -w <<<"$actual" | tr -d ' ')
  expected_count=${#expected[@]}
  if [[ "$actual_count" -ne "$expected_count" ]]; then
    echo "ERROR: $binary arch mismatch (expected: ${expected[*]}, actual: ${actual})" >&2
    exit 1
  fi
  for arch in "${expected[@]}"; do
    if [[ "$actual" != *"$arch"* ]]; then
      echo "ERROR: $binary missing arch $arch (have: ${actual})" >&2
      exit 1
    fi
  done
}

install_binary() {
  local name="$1"
  local dest="$2"
  local binaries=()
  for arch in "${ARCH_LIST[@]}"; do
    local src
    src=$(build_product_path "$name" "$arch")
    if [[ ! -f "$src" ]]; then
      echo "ERROR: Missing ${name} build for ${arch} at ${src}" >&2
      exit 1
    fi
    binaries+=("$src")
  done
  if [[ ${#ARCH_LIST[@]} -gt 1 ]]; then
    lipo -create "${binaries[@]}" -output "$dest"
  else
    cp "${binaries[0]}" "$dest"
  fi
  chmod +x "$dest"
  verify_binary_arches "$dest" "${ARCH_LIST[@]}"
}

install_binary "$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"

# Bundle app resources (if any).
APP_RESOURCES_DIR="$ROOT/Sources/$APP_NAME/Resources"
if [[ -d "$APP_RESOURCES_DIR" ]]; then
  cp -R "$APP_RESOURCES_DIR/." "$APP/Contents/Resources/"
fi

# SwiftPM resource bundles are emitted next to the built binary.
PREFERRED_BUILD_DIR="$(dirname "$(build_product_path "$APP_NAME" "${ARCH_LIST[0]}")")"
shopt -s nullglob
SWIFTPM_BUNDLES=("${PREFERRED_BUILD_DIR}/"*.bundle)
shopt -u nullglob
if [[ ${#SWIFTPM_BUNDLES[@]} -gt 0 ]]; then
  for bundle in "${SWIFTPM_BUNDLES[@]}"; do
    cp -R "$bundle" "$APP/Contents/Resources/"
  done
fi

# Embed frameworks if any exist in the build folder.
FRAMEWORK_DIRS=(".build/$CONF" ".build/${ARCH_LIST[0]}-apple-macosx/$CONF")
for dir in "${FRAMEWORK_DIRS[@]}"; do
  if compgen -G "${dir}/*.framework" >/dev/null; then
    cp -R "${dir}/"*.framework "$APP/Contents/Frameworks/"
    chmod -R a+rX "$APP/Contents/Frameworks"
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/$APP_NAME"
    break
  fi
done

if [[ ! -f "$ICON_TARGET" && -f "$ROOT/Sources/$APP_NAME/Resources/Icon.icns" ]]; then
  ICON_TARGET="$ROOT/Sources/$APP_NAME/Resources/Icon.icns"
fi

if [[ -f "$ICON_TARGET" ]]; then
  cp "$ICON_TARGET" "$APP/Contents/Resources/Icon.icns"
fi

# Ensure contents are writable before stripping attributes and signing.
chmod -R u+w "$APP"

# Strip extended attributes to prevent AppleDouble files that break code sealing.
xattr -cr "$APP"
find "$APP" -name '._*' -delete

ENTITLEMENTS_DIR="$ROOT/.build/entitlements"
DEFAULT_ENTITLEMENTS="$ENTITLEMENTS_DIR/${APP_NAME}.entitlements"
mkdir -p "$ENTITLEMENTS_DIR"

APP_ENTITLEMENTS=${APP_ENTITLEMENTS:-$DEFAULT_ENTITLEMENTS}
if [[ ! -f "$APP_ENTITLEMENTS" ]]; then
  cat > "$APP_ENTITLEMENTS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <!-- Add entitlements here if needed. -->
</dict>
</plist>
PLIST
fi

if [[ "$SIGNING_MODE" == "adhoc" || -z "$APP_IDENTITY" ]]; then
  CODESIGN_ARGS=(--force --sign "-")
else
  CODESIGN_ARGS=(--force --timestamp --options runtime --sign "$APP_IDENTITY")
fi

sign_sparkle() {
  local sparkle="$APP/Contents/Frameworks/Sparkle.framework"
  if [[ ! -d "$sparkle" ]]; then
    return
  fi
  local resign
  resign() { codesign "${CODESIGN_ARGS[@]}" "$1"; }
  resign "$sparkle/Versions/B/XPCServices/Downloader.xpc/Contents/MacOS/Downloader"
  resign "$sparkle/Versions/B/XPCServices/Downloader.xpc"
  resign "$sparkle/Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer"
  resign "$sparkle/Versions/B/XPCServices/Installer.xpc"
  resign "$sparkle/Versions/B/Updater.app/Contents/MacOS/Updater"
  resign "$sparkle/Versions/B/Updater.app"
  resign "$sparkle/Versions/B/Autoupdate"
  resign "$sparkle/Versions/B/Sparkle"
  resign "$sparkle/Versions/B"
  resign "$sparkle"
}

# Sign embedded frameworks and their nested binaries before the app bundle.
sign_frameworks() {
  local fw
  for fw in "$APP/Contents/Frameworks/"*.framework; do
    if [[ ! -d "$fw" ]]; then
      continue
    fi
    while IFS= read -r -d '' bin; do
      codesign "${CODESIGN_ARGS[@]}" "$bin"
    done < <(find "$fw" -type f -perm -111 -print0)
    codesign "${CODESIGN_ARGS[@]}" "$fw"
  done
}
sign_sparkle
sign_frameworks

codesign "${CODESIGN_ARGS[@]}" \
  --entitlements "$APP_ENTITLEMENTS" \
  "$APP"

echo "Created $APP"
echo ""
echo "To build a release app with icons:"
echo "  Scripts/package_app.sh release"
echo ""
echo "Packaged app:"
echo "  $APP"
