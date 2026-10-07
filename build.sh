#!/bin/sh
# Build build/Kiba.app and install it as ~/Applications/Kiba.app, and the
# kiba CLI as ~/.local/bin/kiba.
set -eu

cd "$(dirname "$0")"

# The inherited TMPDIR may not exist, and swiftc fails without one.
TMPDIR=$(mktemp -d /private/tmp/kiba-build-XXXXXX)
export TMPDIR
clean() { rm -rf "$TMPDIR"; }
trap clean EXIT
for sig in HUP INT TERM; do
    trap "clean; trap - EXIT $sig; kill -s $sig \$\$" "$sig"
done

swift build -c release --product Kiba
swift build -c release --product KibaCLI
bin=$(swift build -c release --product Kiba --show-bin-path)

app=build/Kiba.app
plist=$app/Contents/Info.plist
res=$app/Contents/Resources
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$res"
cp "$bin/Kiba" "$app/Contents/MacOS/Kiba"

iconset=$TMPDIR/AppIcon.iconset
swift Scripts/icon.swift "$iconset"
iconutil --convert icns --output "$res/AppIcon.icns" "$iconset"

cat > "$plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>Kiba</string>
    <key>CFBundleExecutable</key>
    <string>Kiba</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>io.github.joelreymont.kiba</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Kiba</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
EOF
plutil -lint -s "$plist"
codesign --force --sign - "$app"

# Copy in full beside the installed app, then swap by rename; the old copy
# goes only once the new one is in place.
dest=$HOME/Applications/Kiba.app
stage=$dest.staging
old=$dest.old
mkdir -p "$HOME/Applications"
rm -rf "$stage" "$old"
ditto "$app" "$stage"
if [ -e "$dest" ] || [ -L "$dest" ]; then
    mv "$dest" "$old"
fi
mv "$stage" "$dest"
rm -rf "$old"
echo "$dest"

# The CLI the Claude Code auto-switch mod runs.
cli=$HOME/.local/bin/kiba
mkdir -p "$HOME/.local/bin"
install -m 0755 "$bin/KibaCLI" "$cli"
echo "$cli"
