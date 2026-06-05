#!/usr/bin/env bash
# Generate a self-signed server cert for the ALB HTTPS listener and import it into ACM.
# The default ALB DNS is wildcard, so SAN is worked around at the client side
# (`curl --resolve` / `-k`). For demos only — production must use an ACM-issued
# cert or a public-CA-issued cert.
#
# Outputs:
#   server/server.key, server/server.crt
#   ACM Certificate ARN printed to stdout.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRV="$ROOT/server"
mkdir -p "$SRV"

REGION="${AWS_REGION:-ap-northeast-2}"

# Git Bash on Windows path-mangling fix.
SUBJ_PREFIX="/"
case "${OSTYPE:-}" in msys*|cygwin*) SUBJ_PREFIX="//" ;; esac

if [[ ! -f "$SRV/server.crt" ]]; then
  echo "=== Generating self-signed server cert ==="
  openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$SRV/server.key" \
    -out "$SRV/server.crt" \
    -days 365 -sha256 \
    -subj "${SUBJ_PREFIX}C=US/ST=Demo/O=Demo/CN=mtls-demo.local" \
    -addext "subjectAltName=DNS:mtls-demo.local,DNS:*.elb.amazonaws.com"
fi

echo "=== Importing into ACM ($REGION) ==="
# AWS CLI on Windows needs native paths, not Git Bash /c/... POSIX paths.
to_native() {
  case "${OSTYPE:-}" in
    msys*|cygwin*) cygpath -w "$1" ;;
    *) printf '%s' "$1" ;;
  esac
}
CRT_PATH="$(to_native "$SRV/server.crt")"
KEY_PATH="$(to_native "$SRV/server.key")"

ARN=$(aws acm import-certificate \
  --region "$REGION" \
  --certificate "fileb://$CRT_PATH" \
  --private-key "fileb://$KEY_PATH" \
  --tags Key=Project,Value=alb-mtls-demo \
  --query CertificateArn --output text)

echo ""
echo "ACM Certificate ARN:"
echo "$ARN"
echo ""
echo "Next step:"
echo "  cdk deploy -c serverCertArn=$ARN"
