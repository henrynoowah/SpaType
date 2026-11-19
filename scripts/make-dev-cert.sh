#!/usr/bin/env bash
# Creates a self-signed "SpaType Dev" code-signing certificate in your login keychain.
# Signing every build with the same certificate keeps the Accessibility / Input Monitoring
# grants across rebuilds (ad-hoc signatures change every build, so macOS forgets them).
set -euo pipefail
NAME="${1:-SpaType Dev}"

if security find-identity -p codesigning 2>/dev/null | grep -q "\"$NAME\""; then
  echo "\"$NAME\" already exists."
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cfg" <<CFG
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CFG
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cfg" 2>/dev/null
PASS="$(/usr/bin/openssl rand -hex 12)"
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
  -out "$TMP/id.p12" -passout "pass:$PASS"
security import "$TMP/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P "$PASS" -T /usr/bin/codesign
echo "Created \"$NAME\". ./scripts/bundle.sh will sign with it from now on."
