#!/bin/sh
# Builds Recast.app into build/, universal (Apple silicon and Intel). Uses Xcode's toolchain when Xcode is installed
# (the Command Line Tools don't include the macOS 26 SDK that SwiftUI's Liquid Glass needs).
#
# A plain ./build.sh makes a local build: ad-hoc signed, with no update feed, so it never checks for updates.
# Release builds set (see "Updates and releases" in the README):
#   SIGN_IDENTITY      codesign identity, e.g. "Developer ID Application: …" (default "-", ad-hoc)
#   UPDATE_FEED_URL    the Sparkle update feed, e.g. https://example.com/updates/recast/appcast.xml
#   UPDATE_PUBLIC_KEY  the EdDSA public key (base64) whose private half signs the updates
set -eu
cd "$(dirname "$0")"
if [ -d /Applications/Xcode.app/Contents/Developer ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
version="${APP_VERSION:-$(tr -d '[:space:]' < VERSION)}"   # APP_VERSION: for update tests only
sign="${SIGN_IDENTITY:--}"
feed="${UPDATE_FEED_URL:-}"
key="${UPDATE_PUBLIC_KEY:-}"
if { [ -n "$feed" ] && [ -z "$key" ]; } || { [ -z "$feed" ] && [ -n "$key" ]; }; then
  echo "Set both UPDATE_FEED_URL and UPDATE_PUBLIC_KEY, or neither." >&2
  exit 1
fi
# SwiftPM sandboxes its manifest builds; inside another sandbox (an automated check runner's, for example) that fails with
# "sandbox_apply: Operation not permitted", so turn SwiftPM's own sandbox off there. Such a sandbox usually has no
# network either, so use the packages SwiftPM already has cached (--skip-update) instead of fetching updates first.
# The packages are public: --disable-keychain stops SwiftPM looking for github.com passwords in the Keychain when it
# downloads Sparkle's framework, which makes macOS ask to use whatever GitHub credentials are saved there.
spm_flags="--disable-keychain"
if ! /usr/bin/sandbox-exec -p '(version 1)(allow default)' /usr/bin/true 2>/dev/null; then spm_flags="$spm_flags --disable-sandbox --skip-update"; fi
# Universal: Apple silicon (arm64) and Intel (x86_64). With more than one --arch, SwiftPM builds with its Xcode-style
# build system, which puts the products in another folder; --show-bin-path with the same flags names it.
arch_flags="--arch arm64 --arch x86_64"
xcrun swift build $spm_flags $arch_flags -c release --product Recast
bindir="$(xcrun swift build $spm_flags $arch_flags -c release --show-bin-path)"
app="build/Recast.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Frameworks"
cp "$bindir/Recast" "$app/Contents/MacOS/Recast"
# Sparkle, for in-app updates. Recast isn't sandboxed, so Sparkle's XPC services aren't needed.
framework="$app/Contents/Frameworks/Sparkle.framework"
ditto "$bindir/Sparkle.framework" "$framework"
rm -rf "$framework/XPCServices" "$framework/Versions/B/XPCServices"
# LAME (GNU LGPL) as its own, replaceable library, with its licence and where to get its source (Packages/Lame).
cp "$bindir/libmp3lame.dylib" "$app/Contents/Frameworks/libmp3lame.dylib"
if ! otool -l "$app/Contents/MacOS/Recast" | grep -q "@executable_path/../Frameworks"; then
  install_name_tool -add_rpath @executable_path/../Frameworks "$app/Contents/MacOS/Recast"
fi
updates=""
if [ -n "$feed" ]; then
  updates="<key>SUFeedURL</key><string>$feed</string>
  <key>SUPublicEDKey</key><string>$key</string>"
fi
if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"; fi
cp Packages/Lame/Sources/CLame/COPYING "$app/Contents/Resources/LAME-COPYING.txt"
cp Packages/Lame/NOTICE.txt "$app/Contents/Resources/LAME-NOTICE.txt"
cp "Sources/COggVorbis/libvorbis-1.3.7/COPYING" "$app/Contents/Resources/libvorbis-COPYING.txt"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Recast</string>
  <key>CFBundleDisplayName</key><string>Recast</string>
  <key>CFBundleIdentifier</key><string>com.kitedrake.recast</string>
  <key>CFBundleExecutable</key><string>Recast</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${version}</string>
  <key>CFBundleVersion</key><string>${version}</string>
  $updates
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Recast by omso. GNU GPL v3 or later. MP3 encoding: LAME 3.100 (LGPL). Ogg Vorbis: libvorbis 1.3.7 (BSD).</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Audio</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key><array><string>public.audio</string><string>public.folder</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST
# Sign from the inside out. Ad-hoc is enough for a local app; a release uses a Developer ID with the hardened
# runtime and a secure timestamp, as notarization requires.
sign_code() {
  if [ "$sign" = "-" ]; then
    codesign --force --sign - "$1"
  else
    codesign --force --sign "$sign" --options runtime --timestamp "$1"
  fi
}
sign_code "$app/Contents/Frameworks/libmp3lame.dylib"
sign_code "$framework/Versions/B/Autoupdate"
sign_code "$framework/Versions/B/Updater.app"
sign_code "$framework"
sign_code "$app"
# Every binary in the bundle must run on Apple silicon and Intel: each Mach-O file needs both architectures.
binaries="$(find "$app" -type f -exec file {} + | sed -n -e '/(for architecture/d' -e 's/:[[:space:]]*Mach-O .*//p')"
[ -n "$binaries" ] || { echo "Found no binaries to check in $app" >&2; exit 1; }
echo "$binaries" | while IFS= read -r binary; do
  archs="$(lipo -archs "$binary")"
  for arch in arm64 x86_64; do
    case " $archs " in *" $arch "*) ;; *) echo "$binary isn't universal (it has $archs)" >&2; exit 1 ;; esac
  done
done
echo "Built $(pwd)/$app"
