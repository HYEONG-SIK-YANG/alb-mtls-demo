#!/usr/bin/env bash
# Simulate a private intermediary CA with OpenSSL for the mTLS demo.
#   v1: current operating CA + client cert
#   v2: rotated CA  (used to simulate a future rotation)
#
# Outputs:
#   ca/v1/intermediary-ca.crt, intermediary-ca.key, client.crt, client.key
#   ca/v2/intermediary-ca.crt, intermediary-ca.key, client.crt, client.key
#   ca/bundle-current.pem      (v1 CA only — steady state)
#   ca/bundle-rollover.pem     (v1 + v2 CA — overlap window for rolling rotation)
#   ca/bundle-rotated.pem      (v2 CA only — after cutover)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CA_DIR="$ROOT/ca"
mkdir -p "$CA_DIR/v1" "$CA_DIR/v2"

# Git Bash on Windows: leading // prevents MSYS from rewriting /C=US/... into a Windows path.
# Detect Git Bash via $OSTYPE so the same script works on Linux/macOS.
SUBJ_PREFIX="/"
case "${OSTYPE:-}" in msys*|cygwin*) SUBJ_PREFIX="//" ;; esac

create_ca_and_client() {
  local version="$1"
  local label="$2"  # display label (e.g. "v1-current")
  local dir="$CA_DIR/$version"

  echo "=== Creating intermediary CA $version ($label) ==="

  # 1) Intermediary CA key + cert
  openssl genrsa -out "$dir/intermediary-ca.key" 2048
  openssl req -x509 -new -nodes -key "$dir/intermediary-ca.key" \
    -sha256 -days 365 \
    -subj "${SUBJ_PREFIX}C=US/ST=Demo/O=Demo-Intermediary/OU=$label/CN=demo-intermediary-$version.local" \
    -out "$dir/intermediary-ca.crt"

  # 2) Client key/CSR/cert (signed by the CA above)
  openssl genrsa -out "$dir/client.key" 2048
  openssl req -new -key "$dir/client.key" \
    -subj "${SUBJ_PREFIX}C=US/ST=Demo/O=Demo-Client/OU=$label/CN=demo-client-$version.local" \
    -out "$dir/client.csr"
  openssl x509 -req -in "$dir/client.csr" \
    -CA "$dir/intermediary-ca.crt" -CAkey "$dir/intermediary-ca.key" \
    -CAcreateserial -days 180 -sha256 \
    -out "$dir/client.crt"

  rm -f "$dir/client.csr" "$dir/intermediary-ca.srl"
  echo "  CA fingerprint: $(openssl x509 -in "$dir/intermediary-ca.crt" -noout -fingerprint -sha256)"
}

create_ca_and_client v1 "v1-current"
create_ca_and_client v2 "v2-rotated"

# Three bundles
cp "$CA_DIR/v1/intermediary-ca.crt" "$CA_DIR/bundle-current.pem"
cat "$CA_DIR/v1/intermediary-ca.crt" "$CA_DIR/v2/intermediary-ca.crt" > "$CA_DIR/bundle-rollover.pem"
cp "$CA_DIR/v2/intermediary-ca.crt" "$CA_DIR/bundle-rotated.pem"

echo ""
echo "=== Bundles ==="
ls -la "$CA_DIR"/*.pem
echo ""
echo "Done. Bundles in: $CA_DIR"
