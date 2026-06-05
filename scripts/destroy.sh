#!/usr/bin/env bash
# Tear down all demo resources.
#   1) cdk destroy → ALB / Lambda / S3 / TrustStore stack resources
#   2) Delete the imported ACM server certificate (ARN must be passed in)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

REGION="${AWS_REGION:-ap-northeast-2}"
SERVER_CERT_ARN="${1:-}"

echo "=== cdk destroy ==="
if [[ -n "$SERVER_CERT_ARN" ]]; then
  npx cdk destroy --force -c "serverCertArn=$SERVER_CERT_ARN"
else
  echo "ERROR: serverCertArn missing. Re-run as:"
  echo "       ./scripts/destroy.sh <SERVER_CERT_ARN>"
  exit 1
fi

echo ""
echo "=== Deleting imported ACM cert ==="
aws acm delete-certificate --region "$REGION" --certificate-arn "$SERVER_CERT_ARN" || true

echo ""
echo "=== Done ==="
echo "Verify:"
echo "  - CloudFormation 'MtlsDemoStack' is fully deleted"
echo "  - ACM has no leftover demo cert"
echo "  - EC2 → Load Balancers shows none of this stack's ALB (avoid hourly billing)"
