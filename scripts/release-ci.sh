#!/bin/sh
# Builds, tests and packs a release of this app: on a GitHub Mac from .github/workflows/release.yml, or locally as a
# dry run (sh scripts/release-ci.sh, with APP_NAME etc. set as in the workflow). The same file lives in every Kitedrake
# app repository; keep the copies identical (the workflow sets everything that differs).
#
# Needs: APP_NAME, UPDATE_FEED_URL, UPDATE_PUBLIC_KEY, MINIMUM_MACOS. RELEASE_TAG (v1.2.3) for a real release: it must
# match VERSION, and the annotated tag's message becomes the release notes (one line per note).
# Optional secrets; each step is skipped without them, and the release is then an unsigned preview:
#   APPLE_CERTIFICATE_P12 (base64 .p12), APPLE_CERTIFICATE_PASSWORD, APPLE_SIGN_IDENTITY   Developer ID signing
#   NOTARY_KEY_P8 (the .p8 file's text), NOTARY_KEY_ID, NOTARY_ISSUER_ID   notarization (App Store Connect API key)
#   SPARKLE_PRIVATE_KEY   signs the update so released copies accept it (in-app updates)
# Writes to out/ (OUT_DIR): <APP_NAME>-<version>.zip, update.json (what the website reads) and notes.md.
set -eu
cd "$(dirname "$0")/.."
: "${APP_NAME:?}" "${UPDATE_FEED_URL:?}" "${UPDATE_PUBLIC_KEY:?}" "${MINIMUM_MACOS:?}"
out="$(pwd)/${OUT_DIR:-out}"
rm -rf "$out"
mkdir -p "$out"
version="$(tr -d '[:space:]' < VERSION)"
tag="${RELEASE_TAG:-}"
if [ -n "$tag" ] && [ "$tag" != "v$version" ]; then
  echo "The tag $tag doesn't match VERSION ($version)." >&2
  exit 1
fi

# Release notes: the annotated tag's message, one note per line (a leading "- " is dropped).
if [ -n "$tag" ]; then
  git fetch --force origin "refs/tags/$tag:refs/tags/$tag" >/dev/null 2>&1 || true
  git for-each-ref "refs/tags/$tag" --format='%(contents)' \
    | sed -e '/^-----BEGIN PGP/,$d' -e 's/^[-*][[:space:]]*//' -e '/^[[:space:]]*$/d' > "$out/notes.txt"
  if [ "$(git cat-file -t "refs/tags/$tag")" != "tag" ] || [ ! -s "$out/notes.txt" ]; then
    echo "Make $tag an annotated tag with the release notes as its message: git tag -a $tag -m '…'" >&2
    exit 1
  fi
else
  echo "Dry run: not a release." > "$out/notes.txt"
fi

# 1. Developer ID signing, from a temporary keychain that only lives for this run.
identity="-"
if [ -n "${APPLE_CERTIFICATE_P12:-}" ]; then
  keychain="${RUNNER_TEMP:-$out}/signing.keychain-db"
  keychain_password="$(uuidgen)"
  security create-keychain -p "$keychain_password" "$keychain"
  security set-keychain-settings -lut 21600 "$keychain"
  security unlock-keychain -p "$keychain_password" "$keychain"
  printf '%s' "$APPLE_CERTIFICATE_P12" | base64 --decode > "$out/certificate.p12"
  security import "$out/certificate.p12" -k "$keychain" -P "${APPLE_CERTIFICATE_PASSWORD:-}" -T /usr/bin/codesign
  rm -f "$out/certificate.p12"
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$keychain_password" "$keychain" >/dev/null
  security list-keychains -d user -s "$keychain" $(security list-keychains -d user | tr -d '"')
  identity="${APPLE_SIGN_IDENTITY:?APPLE_SIGN_IDENTITY names the Developer ID Application identity}"
fi

# 2. Build with the update feed, then test the engine and the built app.
SIGN_IDENTITY="$identity" UPDATE_FEED_URL="$UPDATE_FEED_URL" UPDATE_PUBLIC_KEY="$UPDATE_PUBLIC_KEY" ./build.sh
app="build/$APP_NAME.app"
./test.sh
"$app/Contents/MacOS/$APP_NAME" --self-test "$out/self-test"
rm -rf "$out/self-test"
codesign --verify --deep --strict "$app"

archive="$out/$APP_NAME-$version.zip"
pack() { rm -f "$archive"; ditto -c -k --sequesterRsrc --keepParent "$app" "$archive"; }
pack

# 3. Notarize and staple (needs the Developer ID signature).
notarized=false
if [ -n "${NOTARY_KEY_P8:-}" ] && [ "$identity" != "-" ]; then
  printf '%s\n' "$NOTARY_KEY_P8" > "$out/notary-key.p8"
  xcrun notarytool submit "$archive" --key "$out/notary-key.p8" --key-id "${NOTARY_KEY_ID:?}" \
    --issuer "${NOTARY_ISSUER_ID:?}" --wait
  rm -f "$out/notary-key.p8"
  xcrun stapler staple "$app"
  pack
  notarized=true
fi

# 4. Sign the update for Sparkle.
signature=""
if [ -n "${SPARKLE_PRIVATE_KEY:-}" ]; then
  printf '%s\n' "$SPARKLE_PRIVATE_KEY" > "$out/sparkle-key.txt"
  signature="$(.build/artifacts/sparkle/Sparkle/bin/sign_update -p --ed-key-file "$out/sparkle-key.txt" "$archive")"
  rm -f "$out/sparkle-key.txt"
fi

# 5. What the website reads (update.json, attached to the release), and the release's description.
python3 - "$out" "$version" "$MINIMUM_MACOS" "$(wc -c < "$archive" | tr -d ' ')" "$signature" \
  "$([ "$identity" != "-" ] && echo true || echo false)" "$notarized" <<'PY'
import json, sys
out, version, minimum, length, signature, signed, notarized = sys.argv[1:]
notes = [line.strip() for line in open(f"{out}/notes.txt", encoding="utf-8") if line.strip()]
record = {"version": version, "minimum_macos": minimum, "notes": notes, "length": int(length),
          "signature": signature or None, "signed": signed == "true", "notarized": notarized == "true"}
json.dump(record, open(f"{out}/update.json", "w", encoding="utf-8"), indent=2, ensure_ascii=False)
body = "\n".join(f"- {n}" for n in notes)
if not record["notarized"]:
    body += ("\n\n**Preview build.** It isn't signed and notarized by Apple yet, so macOS blocks it at first: "
             "open it once, then allow it in System Settings › Privacy & Security.")
body += f"\n\nRequires macOS {minimum} or later on a Mac with Apple silicon."
open(f"{out}/notes.md", "w", encoding="utf-8").write(body + "\n")
PY
rm -f "$out/notes.txt"
echo "Packed $(basename "$archive") (signed: $([ "$identity" != "-" ] && echo yes || echo no), notarized: $notarized, update signature: $([ -n "$signature" ] && echo yes || echo no))"
