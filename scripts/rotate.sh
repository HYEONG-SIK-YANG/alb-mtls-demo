#!/usr/bin/env bash
# Trust store rotation helper.
#   $1 = bundle key (ca/bundle-rollover.pem | ca/bundle-rotated.pem | ca/bundle-current.pem)
#
# Steps:
#   1) Upload local ca/<bundle> to S3 (versioned)
#   2) Invoke the Rotator Lambda with action=rotate
#
# Required env vars:
#   ROTATOR_FN    — cdk output RotatorFunctionName
#   BUNDLE_BUCKET — cdk output BundleBucketName
set -euo pipefail

KEY="${1:-}"
if [[ -z "$KEY" ]]; then
  echo "Usage: $0 <bundle-key>   (e.g. ca/bundle-rollover.pem)"
  exit 1
fi
: "${ROTATOR_FN:?ROTATOR_FN env var required (cdk output RotatorFunctionName)}"
: "${BUNDLE_BUCKET:?BUNDLE_BUCKET env var required (cdk output BundleBucketName)}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOCAL="$ROOT/$KEY"

if [[ ! -f "$LOCAL" ]]; then
  echo "missing local file: $LOCAL"
  exit 1
fi

echo "=== Uploading $LOCAL → s3://$BUNDLE_BUCKET/$KEY ==="
aws s3 cp "$LOCAL" "s3://$BUNDLE_BUCKET/$KEY"

echo "=== Invoking rotator ==="
aws lambda invoke \
  --function-name "$ROTATOR_FN" \
  --cli-binary-format raw-in-base64-out \
  --payload "{\"action\":\"rotate\",\"bundleKey\":\"$KEY\"}" \
  /tmp/rotator-out.json

echo ""
echo "--- rotator response ---"
cat /tmp/rotator-out.json
echo
