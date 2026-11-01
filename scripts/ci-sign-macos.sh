#!/usr/bin/env bash
# Signs the app and spike tools for distribution.
#
#   scripts/ci-sign-macos.sh <Jeeves.app> <tools-dir> <entitlements.plist>
#
# Without MACOS_CERTIFICATE_P12 everything is signed ad-hoc ("-"): it runs on Apple
# silicon, but macOS shows an "could not verify" warning on first open.
# With these secrets set, it signs with a Developer ID certificate and notarizes:
#   MACOS_CERTIFICATE_P12       base64 of a .p12 holding "Developer ID Application: ..."
#   MACOS_CERTIFICATE_PASSWORD  the .p12 password
#   NOTARY_KEY_P8               App Store Connect API key (.p8 contents, PEM text)
#   NOTARY_KEY_ID, NOTARY_ISSUER_ID  that key's ID and issuer ID
set -euo pipefail

APP="$1"
TOOLS_DIR="$2"
ENTITLEMENTS="$3"
TMP="${RUNNER_TEMP:-$(mktemp -d)}"

if [[ -n "${MACOS_CERTIFICATE_P12:-}" ]]; then
  keychain="$TMP/jeeves-signing.keychain-db"
  keychain_password="$(uuidgen)"
  security create-keychain -p "$keychain_password" "$keychain"
  security set-keychain-settings -lut 21600 "$keychain"
  security unlock-keychain -p "$keychain_password" "$keychain"
  printf '%s' "$MACOS_CERTIFICATE_P12" | base64 --decode > "$TMP/certificate.p12"
  security import "$TMP/certificate.p12" -k "$keychain" -P "${MACOS_CERTIFICATE_PASSWORD:-}" -T /usr/bin/codesign
  rm -f "$TMP/certificate.p12"
  security set-key-partition-list -S apple-tool:,apple: -s -k "$keychain_password" "$keychain" >/dev/null
  # shellcheck disable=SC2046
  security list-keychains -d user -s "$keychain" $(security list-keychains -d user | tr -d '"')
  identity="$(security find-identity -v -p codesigning "$keychain" \
    | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"')"
  if [[ -z "$identity" ]]; then
    echo "::error::MACOS_CERTIFICATE_P12 has no 'Developer ID Application' identity"
    exit 1
  fi
  echo "Signing with: $identity"
  sign_flags=(--force --options runtime --timestamp --sign "$identity")
else
  echo "::notice::No signing certificate configured: signing ad-hoc. macOS will warn on first open; see docs/M0.md."
  sign_flags=(--force --options runtime --sign -)
fi

# Nested code first (none today: Swift packages link statically), then the app.
while IFS= read -r -d '' nested; do
  codesign "${sign_flags[@]}" "$nested"
done < <(find "$APP/Contents" \( -name '*.dylib' -o -name '*.framework' -o -name '*.xpc' \) -print0)
codesign "${sign_flags[@]}" --entitlements "$ENTITLEMENTS" "$APP"

for tool in "$TOOLS_DIR"/spike-*; do
  codesign "${sign_flags[@]}" "$tool"
done

codesign --verify --strict --verbose=2 "$APP"
codesign --display --entitlements - "$APP" 2>/dev/null | tail -n +1 || true
codesign --display --verbose=2 "$APP" 2>&1 | grep -E '^(Identifier|Authority|Signature|CodeDirectory|TeamIdentifier)' || true

if [[ -n "${MACOS_CERTIFICATE_P12:-}" && -n "${NOTARY_KEY_P8:-}" ]]; then
  key="$TMP/notary-key.p8"
  printf '%s\n' "$NOTARY_KEY_P8" > "$key"
  notarize() {
    xcrun notarytool submit "$1" --key "$key" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID" \
      --wait --timeout 30m
  }
  ditto -c -k --keepParent "$APP" "$TMP/app-for-notary.zip"
  notarize "$TMP/app-for-notary.zip"
  xcrun stapler staple "$APP"
  # Command-line tools cannot be stapled; Gatekeeper checks their notarization online.
  ditto -c -k --keepParent "$TOOLS_DIR" "$TMP/tools-for-notary.zip"
  notarize "$TMP/tools-for-notary.zip"
  spctl --assess --type execute --verbose=2 "$APP"
  rm -f "$key"
fi
