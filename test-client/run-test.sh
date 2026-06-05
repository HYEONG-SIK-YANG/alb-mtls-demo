#!/usr/bin/env bash
# mTLS verification scenarios:
#   1) v1 client cert        → 200 OK + mTLS headers
#   2) no client cert        → TLS handshake refused
#   3) v2 client cert        → refused while TrustStore holds v1 only
#   4) [after rotation]      → v2 client cert returns 200 once the rollover or
#                              rotated bundle is applied
#
# Usage:
#   ./run-test.sh <ALB_DNS_NAME>
set -euo pipefail

ALB="${1:-}"
if [[ -z "$ALB" ]]; then
  echo "Usage: $0 <ALB_DNS_NAME>"
  echo "  (the cdk output 'AlbDnsName' value)"
  exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
URL="https://$ALB/echo"

run() {
  local name="$1"; shift
  echo ""
  echo "===== $name ====="
  echo "+ curl $*"
  set +e
  curl -sS -o /tmp/mtls-body -w "HTTP %{http_code}  TLS %{ssl_verify_result}\n" "$@" || true
  set -e
  if [[ -s /tmp/mtls-body ]]; then
    echo "--- response body ---"
    cat /tmp/mtls-body
    echo
  fi
}

# 1) v1 — expected 200
run "1) v1 client cert → expect 200" \
  -k --tlsv1.3 \
  --cert "$ROOT/ca/v1/client.crt" --key "$ROOT/ca/v1/client.key" \
  "$URL"

# 2) no cert — expected handshake error
run "2) no client cert → expect TLS error / 4xx" \
  -k --tlsv1.3 \
  "$URL"

# 3) v2 — expected handshake error while TrustStore holds v1 only
run "3) v2 client cert (TrustStore=v1 only) → expect TLS error" \
  -k --tlsv1.3 \
  --cert "$ROOT/ca/v2/client.crt" --key "$ROOT/ca/v2/client.key" \
  "$URL"

echo ""
echo "Next: apply the rollover bundle and re-run scenario 3 — it should return 200."
echo "  ./scripts/rotate.sh ca/bundle-rollover.pem"
