#!/usr/bin/env bash
# Sign the macOS Deskflow Dev.app with the stable local "Deskflow Local"
# identity so TCC grants (Accessibility / input control / Screen Recording)
# survive rebuilds.
#
# Why: TCC stores the *code requirement* of the binary. Ad-hoc signatures pin
# the cdhash, so every rebuild invalidates the grant — the app and the inner
# deskflow-core must then be removed and re-added, and macOS keeps re-prompting
# ("Control this Mac and access data") because the identity never stabilises.
# A self-signed certificate makes each requirement
# `identifier … and certificate leaf = H"…"`, which survives rebuilds.
#
#   tools/macos-dev-signing.sh setup                # create + import (idempotent)
#   tools/macos-dev-signing.sh sign [App.app]       # sign /Applications/Deskflow Dev.app
#   tools/macos-dev-signing.sh status [App.app]     # show identity + requirements
#
# Signing order matters: the inner core is signed first, then the bundle, so
# the app's resource seal covers the core's new signature. Quit the app before
# signing.
set -euo pipefail

identity="Deskflow Local"
signing_dir="$HOME/.config/deskflow/signing"
keychain="$HOME/Library/Keychains/login.keychain-db"

setup() {
  mkdir -p "$signing_dir"
  chmod 700 "$signing_dir"
  if [[ ! -f "$signing_dir/cert.pem" || ! -f "$signing_dir/key.pem" ]]; then
    /usr/bin/openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
      -keyout "$signing_dir/key.pem" -out "$signing_dir/cert.pem" \
      -subj "/CN=$identity" \
      -addext "basicConstraints=critical,CA:false" \
      -addext "keyUsage=critical,digitalSignature" \
      -addext "extendedKeyUsage=critical,codeSigning" >/dev/null 2>&1
    chmod 600 "$signing_dir/key.pem"
    echo "created $signing_dir/cert.pem"
  fi
  # Security.framework rejects an empty PKCS#12 password, so use a throwaway one.
  /usr/bin/openssl pkcs12 -export -inkey "$signing_dir/key.pem" -in "$signing_dir/cert.pem" \
    -out "$signing_dir/id.p12" -passout pass:dfw -name "$identity" \
    -macalg sha1 -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES >/dev/null 2>&1
  security import "$signing_dir/id.p12" -k "$keychain" -P dfw \
    -T /usr/bin/codesign -T /usr/bin/security >/dev/null
  rm -f "$signing_dir/id.p12"
  echo "imported identity: $identity"
  echo "  material: $signing_dir (private key — keep it out of the repo)"
}

sign_app() {
  local app="${1:-/Applications/Deskflow Dev.app}"
  local core="$app/Contents/MacOS/deskflow-core"
  [[ -x "$core" ]] || {
    echo "missing $core" >&2
    exit 2
  }
  codesign --force --sign "$identity" --identifier deskflow-core "$core"
  codesign --force --sign "$identity" "$app"
  codesign --verify --strict "$app"
  echo "signed: $app"
  codesign -d -r- "$core" 2>&1 | grep -E '^designated' || true
  codesign -d -r- "$app" 2>&1 | grep -E '^designated' || true
}

status() {
  local app="${1:-/Applications/Deskflow Dev.app}"
  security find-certificate -c "$identity" -Z "$keychain" 2>/dev/null | head -4 || true
  for bin in "$app/Contents/MacOS/deskflow-core" "$app"; do
    echo "# $bin"
    codesign -d -r- "$bin" 2>&1 | grep -E '^designated' || echo "  (not signed)"
  done
}

case "${1:-}" in
setup) setup ;;
sign) sign_app "${2:-}" ;;
status) status "${2:-}" ;;
*)
  echo "usage: $0 {setup|sign [App.app]|status [App.app]}" >&2
  exit 2
  ;;
esac
