#!/bin/zsh
# Builds OS+.app (release), ad-hoc signs it, and installs it to /Applications.
# The app is called "OS+" everywhere you see it. Internally (Swift targets, executable, bundle id
# local.workbench) it's still "Workbench": keeping the bundle id is what keeps granted permissions.
#   scripts/build-app.sh            build + install + launch
#   scripts/build-app.sh --no-install   just build into ./build
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$PWD
APP_NAME="Workbench"          # executable name (internal)
DISPLAY_NAME="OS+"            # what you see in the menu bar, Finder and permission prompts
OLD_DISPLAY_NAMES=("Workbench")  # earlier installs to remove (only if they're ours)
BUNDLE_ID="local.workbench"
VERSION="0.1.0"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/$DISPLAY_NAME.app"
INSTALL_DIR="/Applications"

echo "==> Building release binary"
swift build -c release --arch arm64 2>&1 | grep -E "error|warning:|Compiling|Build complete" || true
BIN="$(swift build -c release --arch arm64 --show-bin-path)/$APP_NAME"
[[ -x "$BIN" ]] || { echo "Build failed: $BIN missing"; exit 1; }

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
[[ -f "$ROOT/Resources/AppIcon.icns" ]] && cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$DISPLAY_NAME</string>
    <key>CFBundleDisplayName</key><string>$DISPLAY_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$(date +%Y%m%d%H%M)</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>Personal use.</string>
    <key>NSAudioCaptureUsageDescription</key><string>OS+ changes individual apps' volume by routing their sound through itself. Nothing is recorded or saved.</string>
    <key>NSScreenCaptureUsageDescription</key><string>OS+ reads text from the area of the screen you select.</string>
    <key>NSDesktopFolderUsageDescription</key><string>OS+ looks for screenshots and measures folders you ask about.</string>
    <key>NSDocumentsFolderUsageDescription</key><string>OS+ measures project dependency folders to show what's using space.</string>
    <key>NSDownloadsFolderUsageDescription</key><string>OS+ lists and tidies your downloads.</string>
</dict>
</plist>
PLIST

echo "==> Signing (ad-hoc, with a stable designated requirement)"
# Ad-hoc signatures change with every build, and macOS ties privacy permissions (Screen Recording,
# Downloads access) to the signature, so they'd reset on every update. Pinning the designated
# requirement to the bundle identifier lets later builds keep the permissions granted earlier.
# Trade-off: any other ad-hoc app claiming this identifier would match. Fine for a personal tool.
codesign --force --sign - --timestamp=none -r="designated => identifier \"$BUNDLE_ID\"" "$APP"
codesign --verify "$APP"
codesign -d -r- "$APP" 2>&1 | grep designated

if [[ "${1:-}" == "--no-install" ]]; then
    echo "Built $APP"
    exit 0
fi

echo "==> Installing to $INSTALL_DIR"
TARGET="$INSTALL_DIR/$DISPLAY_NAME.app"
is_ours() { [[ "$(defaults read "$1/Contents/Info" CFBundleIdentifier 2>/dev/null)" == "$BUNDLE_ID" ]]; }
if [[ -d "$TARGET" ]] && ! is_ours "$TARGET"; then
    echo "Refusing to replace $TARGET: it isn't ours."
    exit 1
fi
pkill -x "$APP_NAME" 2>/dev/null && sleep 0.5 || true
rm -rf "$TARGET"
cp -R "$APP" "$TARGET"
# Remove copies installed under an old name, but only if they're this app.
for old in "${OLD_DISPLAY_NAMES[@]}"; do
    if [[ -d "$INSTALL_DIR/$old.app" ]] && is_ours "$INSTALL_DIR/$old.app"; then
        rm -rf "$INSTALL_DIR/$old.app"
        echo "Removed old $INSTALL_DIR/$old.app"
    fi
done

echo "==> Launching"
open "$TARGET"
echo "Installed $TARGET"
