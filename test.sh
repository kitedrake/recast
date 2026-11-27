#!/bin/sh
# Runs the engine tests. Uses Xcode's toolchain when Xcode is installed (see build.sh).
set -eu
cd "$(dirname "$0")"
if [ -d /Applications/Xcode.app/Contents/Developer ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
# Inside another sandbox SwiftPM's own one can't start, and there's usually no network: turn it off and use the cached
# packages there (see build.sh). --disable-keychain: SwiftPM never asks the Keychain for GitHub credentials.
spm_flags="--disable-keychain"
if ! /usr/bin/sandbox-exec -p '(version 1)(allow default)' /usr/bin/true 2>/dev/null; then spm_flags="$spm_flags --disable-sandbox --skip-update"; fi
xcrun swift test $spm_flags "$@"
