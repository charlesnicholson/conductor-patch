#!/bin/sh
# Build "Conductor QoL Patched.app".
#
# The only external ingredient is brotli, which envy fetches and builds as static
# archives; everything else the tool uses ships with macOS. The result links against
# libSystem, Foundation, AppKit and the OS Swift runtime and nothing else, so it runs on
# any Mac without envy, Homebrew or this checkout.
#
#   ./build.sh              build into out/
#   ./build.sh --install    build, then install into /Applications

set -eu

ROOT=$(cd "$(dirname "$0")" && pwd)
OUT="$ROOT/out"
APP_NAME="Conductor QoL Patched"
BUNDLE_ID="com.charlesnicholson.conductor-qol"
EXECUTABLE="conductor-qol"
APP="$OUT/$APP_NAME.app"

INSTALL=no
for argument in "$@"; do
    case "$argument" in
        --install) INSTALL=yes ;;
        *) echo "usage: $0 [--install]" >&2; exit 2 ;;
    esac
done

echo "==> envy sync"
"$ROOT/bin/envy" sync

BROTLI_INCLUDE=$("$ROOT/bin/envy" product brotli_include_dir | tail -1)
BROTLI_LIB=$("$ROOT/bin/envy" product brotli_lib_dir | tail -1)
[ -f "$BROTLI_INCLUDE/brotli/encode.h" ] || { echo "no brotli headers at $BROTLI_INCLUDE" >&2; exit 1; }
[ -f "$BROTLI_LIB/libbrotlienc.a" ] || { echo "no brotli archives at $BROTLI_LIB" >&2; exit 1; }

echo "==> swiftc"
mkdir -p "$OUT"
xcrun swiftc \
    -O -swift-version 5 \
    -target arm64-apple-macos13.0 \
    -import-objc-header "$ROOT/src/shim.h" \
    -I "$BROTLI_INCLUDE" \
    -framework AppKit \
    "$BROTLI_LIB/libbrotlienc.a" \
    "$BROTLI_LIB/libbrotlidec.a" \
    "$BROTLI_LIB/libbrotlicommon.a" \
    -o "$OUT/$EXECUTABLE" \
    "$ROOT"/src/*.swift

echo "==> bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mv "$OUT/$EXECUTABLE" "$APP/Contents/MacOS/$EXECUTABLE"

# LSUIElement: this is an agent. It has no windows of its own, it lives in the menu bar
# for the length of the Conductor session, and a Dock tile next to Conductor's would only
# be confusing. The bundle identifier is deliberately NOT com.conductor.app.
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>        <string>en</string>
    <key>CFBundleDisplayName</key>              <string>$APP_NAME</string>
    <key>CFBundleExecutable</key>               <string>$EXECUTABLE</string>
    <key>CFBundleIdentifier</key>               <string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key>    <string>6.0</string>
    <key>CFBundleName</key>                     <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>              <string>APPL</string>
    <key>CFBundleShortVersionString</key>       <string>1.0</string>
    <key>CFBundleVersion</key>                  <string>1</string>
    <key>LSMinimumSystemVersion</key>           <string>13.0</string>
    <key>LSUIElement</key>                      <true/>
    <key>NSHighResolutionCapable</key>          <true/>
</dict>
</plist>
PLIST

echo "==> codesign"
codesign --force --sign - --options runtime "$APP"
codesign --verify --strict "$APP"

echo "built $APP"
otool -L "$APP/Contents/MacOS/$EXECUTABLE" | sed 1d | sed 's/^/    /'

if [ "$INSTALL" = yes ]; then
    echo "==> install"
    rm -rf "/Applications/$APP_NAME.app"
    cp -c -R "$APP" "/Applications/$APP_NAME.app"
    echo "installed /Applications/$APP_NAME.app"
fi
